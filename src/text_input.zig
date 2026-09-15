// SPDX-License-Identifier: BSD-2-Clause

//! Editing a string: where the cursor is, what is selected, and what each key
//! does to both.
//!
//! Ply's `text_input.rs` without the half of it that deals with inline markup
//! - `{red|like this}` - which is the rich-text milestone and is not needed to
//! type a name into a box. What is here is the whole plain model: movement by
//! character, word and line, selection, insertion, the four kinds of deletion,
//! undo and redo under Ply's grouping rules, and the two scroll offsets that
//! keep the cursor on screen.
//!
//! **None of it knows what a font is.** A `TextEdit` is a string and two
//! numbers, so every rule below is checked without a window, a measurer or a
//! layout. `Ui` brings those and does the drawing; this decides what the text
//! says.
//!
//! ## Positions are byte offsets
//!
//! Ply counts in `char`s - Rust's code point - and pays for it: almost every
//! method calls `text.chars().count()`, which walks the whole string. Zig has
//! no such type, and a byte offset into UTF-8 is both the natural index and
//! the one a slice already wants, so `cursor` and `anchor` are byte offsets.
//! They are always on a code point boundary, and `next` and `previous` are
//! what keeps them there.
//!
//! Nothing a caller can see changes. The cursor still moves one *character*
//! at a time through "árvíztűrő tükörfúrógép" rather than one byte, and
//! `max_length` is still counted in characters, because that is what a length
//! limit means to whoever set it.

const std = @import("std");
const testing = std.testing;

const Color = @import("color.zig").Color;
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");
const markup = @import("markup.zig");
const text_mod = @import("text.zig");

const Vec2 = geometry.Vec2;

/// How many undone edits are kept. Ply's number.
pub const max_undo = 200;

/// What a password input draws instead of the character. Ply's, and it is
/// three bytes of UTF-8 rather than one, which is the first place a port that
/// assumed one byte per character comes apart.
pub const bullet = "\u{2022}";

// -------------------------------------------------------------------------
// What the caller declares
// -------------------------------------------------------------------------

/// A text input, as an element asks for one. Ply's `TextInputConfig` under a
/// `TextInputBuilder`; here it is the struct itself, because Zig does not
/// need a builder to give a literal defaults.
pub const Config = struct {
    /// Shown, in `placeholder_color`, while the text is empty.
    placeholder: []const u8 = "",
    /// The longest the text may get, **in characters**, or null for no limit.
    max_length: ?usize = null,
    /// Draw `bullet` for every character instead of the character.
    ///
    /// A disguise and not a secret: the text is in memory in the clear, and
    /// this stops a shoulder rather than a debugger.
    password: bool = false,
    /// Whether Enter inserts a newline instead of submitting, and whether the
    /// text wraps and scrolls up and down.
    multiline: bool = false,
    /// Whether dragging inside the box selects text. Off means a drag
    /// scrolls, which is what a touch screen wants.
    drag_select: bool = false,
    /// Whether the text is markup: `{color=red|edited like this}`.
    ///
    /// The cursor still moves through the characters the reader sees - the
    /// tags are not in their way - and what a program reads back is the
    /// string with the tags in. Typing one of the four syntax characters
    /// stores it escaped, so a brace is a brace and not the start of a tag.
    /// See `markup`.
    markup: bool = false,

    font_size: u16 = 16,
    text_color: Color = .white,
    placeholder_color: Color = .bytes(128, 128, 128, 255),
    cursor_color: Color = .white,
    /// The wash behind selected text. Half transparent, so the glyphs still
    /// read through it.
    selection_color: Color = .bytes(69, 130, 181, 128),
    /// Baseline to baseline, or zero for whatever the font says.
    line_height: u16 = 0,
    /// A bar down the edge once there is more text than box. See
    /// `layout.Scrollbar`.
    scrollbar: ?layout.Scrollbar = null,

    /// The style the text is measured and drawn with.
    ///
    /// A single-line input never wraps however long it gets - it scrolls
    /// sideways instead, which is the whole difference between the two modes
    /// as far as the layout is concerned.
    pub fn style(self: Config) text_mod.TextStyle {
        return .{
            .color = self.text_color,
            .font_size = self.font_size,
            .line_height = self.line_height,
            .wrap = if (self.multiline) .words else .none,
        };
    }

    /// The same style in the placeholder's colour.
    pub fn placeholderStyle(self: Config) text_mod.TextStyle {
        var out = self.style();
        out.color = self.placeholder_color;
        return out;
    }

    /// The lengths in it multiplied by an interface scale. See
    /// `layout.Surface.scale`.
    pub inline fn scaled(self: Config, by: f32) Config {
        var out = self;
        out.font_size = geometry.scaleWhole(self.font_size, by);
        out.line_height = geometry.scaleWhole(self.line_height, by);
        if (self.scrollbar) |configured| out.scrollbar = configured.scaled(by);
        return out;
    }
};

// -------------------------------------------------------------------------
// What a key does
// -------------------------------------------------------------------------

/// One editing action, as Ply's `TextInputAction`.
///
/// **The host decides which key means which action**, and that is deliberate.
/// Ply reads macroquad's keyboard from inside the engine; this library has no
/// platform layer and never will, so Ctrl versus Cmd, dead keys, key repeat
/// and the layout the reader actually has are the program's business. What is
/// ported is everything after that decision, which is where the behaviour
/// lives.
pub const Action = union(enum) {
    /// Move the cursor, and maybe drag the selection with it.
    move: Move,
    /// Delete backwards, or the selection if there is one.
    backspace,
    /// Delete forwards, or the selection if there is one.
    delete,
    /// Delete back to the start of the word.
    backspace_word,
    /// Delete forward over the word *and the space after it*, which is Ply's
    /// choice and every editor's.
    delete_word,
    select_all,
    /// Neither of these touches a clipboard - this library has none. `copy`
    /// and `cut` are answered with the selected text, and the host puts it
    /// wherever it keeps such things.
    copy,
    cut,
    paste: []const u8,
    /// Enter. Inserts a newline in a multiline input and is reported to the
    /// caller in either case.
    submit,
    undo,
    redo,

    /// `.moveTo(.left, shift)` rather than a nested literal, because this is
    /// written at every key a program binds.
    pub inline fn moveTo(where: Move.Where, select: bool) Action {
        return .{ .move = .{ .to = where, .select = select } };
    }
};

pub const Move = struct {
    to: Where,
    /// Whether to extend the selection instead of dropping it. Shift.
    select: bool = false,

    pub const Where = enum {
        left,
        right,
        word_left,
        word_right,
        /// Home and End. **The line** in a multiline input and **the whole
        /// text** in a single-line one, decided here rather than by the host
        /// - a program binding a key should not have to know which kind of
        /// field happens to have the keyboard.
        start,
        end,
        /// Ctrl+Home and Ctrl+End: the whole text, whatever the mode.
        text_start,
        text_end,
        up,
        down,
    };
};

/// Why an edit happened, which decides whether it joins the one before it in
/// the undo stack. Ply's `UndoActionKind`.
///
/// Typing a word is one undo, not eight, and holding backspace is one undo
/// and not thirty - so those three group. Pasting, cutting and deleting a
/// word are each deliberate and each stand alone.
pub const EditKind = enum {
    insert,
    paste,
    backspace,
    delete,
    delete_word,
    cut,
    other,

    inline fn groups(self: EditKind) bool {
        return switch (self) {
            .insert, .backspace, .delete => true,
            else => false,
        };
    }
};

/// A byte range, `start` inclusive and `end` exclusive, as everything here
/// hands one over.
pub const Range = struct {
    start: usize,
    end: usize,

    pub inline fn empty(self: Range) bool {
        return self.start >= self.end;
    }
};

// -------------------------------------------------------------------------
// Walking UTF-8
// -------------------------------------------------------------------------

/// The offset of the next character after `at`, or the end.
///
/// A malformed byte is stepped over one at a time rather than refused. A text
/// input is where invalid UTF-8 arrives - a paste from somewhere else, a file
/// read with the wrong assumption - and an editor that returns an error
/// instead of letting the reader fix it is the less useful of the two.
pub fn next(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    const length = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    return @min(at + length, text.len);
}

/// The offset of the character before `at`, or zero.
pub fn previous(text: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = @min(at, text.len);
    // Back over the continuation bytes, which all start `10`. At most three
    // of them, and the bound is what stops a run of stray continuation bytes
    // walking to the front of the string.
    var steps: usize = 0;
    while (i > 0 and steps < 4) {
        i -= 1;
        steps += 1;
        if (text[i] & 0xC0 != 0x80) break;
    }
    return i;
}

/// How many characters a string is, which is what a length limit counts.
pub fn characters(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (count += 1) i = next(text, i);
    return count;
}

/// The code point at `at`, or null at the end. Invalid bytes come back as
/// themselves, for the same reason `next` steps over them.
pub fn codepointAt(text: []const u8, offset: usize) ?u21 {
    if (offset >= text.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch return text[offset];
    if (offset + length > text.len) return text[offset];
    return std.unicode.utf8Decode(text[offset..][0..length]) catch text[offset];
}

/// Whether a code point counts as a space when looking for a word boundary.
///
/// Unicode's White_Space, which is what Rust's `char::is_whitespace` answers
/// and so what Ply's word movement is built on. Doing only ASCII here would
/// make Ctrl+Left walk straight through a non-breaking space, and a
/// non-breaking space is exactly the character somebody pastes in.
pub fn isSpace(code: u21) bool {
    return switch (code) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        0x85, 0xA0, 0x1680 => true,
        0x2000...0x200A => true,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn spaceAt(text: []const u8, offset: usize) bool {
    return isSpace(codepointAt(text, offset) orelse return false);
}

// -------------------------------------------------------------------------
// Lines
// -------------------------------------------------------------------------

/// The start of the line `offset` is on. Lines are separated by `\n` and
/// nothing else - a lone carriage return is a character like any other.
pub fn lineStart(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0) {
        const before = previous(text, i);
        if (text[before] == '\n') return i;
        i = before;
    }
    return 0;
}

/// The end of the line `offset` is on: the offset of its `\n`, or the end of
/// the text.
pub fn lineEnd(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i < text.len and text[i] != '\n') i = next(text, i);
    return i;
}

/// Which line an offset is on and how many characters into it.
///
/// The column is in characters rather than bytes, because it is what up and
/// down aim for and a reader thinks of it as a position on screen, not a
/// number of bytes.
pub fn lineAndColumn(text: []const u8, offset: usize) struct { line: usize, column: usize } {
    var line: usize = 0;
    var column: usize = 0;
    var i: usize = 0;
    const stop = @min(offset, text.len);
    while (i < stop) {
        if (text[i] == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
        i = next(text, i);
    }
    return .{ .line = line, .column = column };
}

/// The offset of a line and column, clamped to the end of that line if the
/// column runs past it - which is what makes up and down through a short line
/// land somewhere sensible rather than nowhere.
pub fn offsetOfLineColumn(text: []const u8, line: usize, column: usize) usize {
    var current_line: usize = 0;
    var i: usize = 0;
    while (current_line < line and i < text.len) : (i = next(text, i)) {
        if (text[i] == '\n') current_line += 1;
    }
    if (current_line < line) return text.len;

    var current_column: usize = 0;
    while (current_column < column and i < text.len and text[i] != '\n') : (current_column += 1) {
        i = next(text, i);
    }
    return i;
}

/// How many lines there are, counting the one after the last newline.
pub fn lineCount(text: []const u8) usize {
    var lines: usize = 1;
    for (text) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

// -------------------------------------------------------------------------
// Words
// -------------------------------------------------------------------------

/// Where Ctrl+Left goes: back over any spaces, then back over the word.
pub fn wordLeft(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0 and spaceAt(text, previous(text, i))) i = previous(text, i);
    while (i > 0 and !spaceAt(text, previous(text, i))) i = previous(text, i);
    return i;
}

/// Where Ctrl+Right goes: forward over any spaces, then to the end of the
/// word. The mirror of `wordLeft`, and *not* the same as what Ctrl+Delete
/// removes.
pub fn wordRight(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i < text.len and spaceAt(text, i)) i = next(text, i);
    while (i < text.len and !spaceAt(text, i)) i = next(text, i);
    return i;
}

/// What Ctrl+Delete removes: the word **and the space after it**, so deleting
/// a word out of a sentence does not leave two spaces where it was.
///
/// The other order from `wordRight`, and the difference is the whole reason
/// Ply has both.
pub fn wordDeleteRight(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i < text.len and !spaceAt(text, i)) i = next(text, i);
    while (i < text.len and spaceAt(text, i)) i = next(text, i);
    return i;
}

/// The word a double click lands in.
///
/// On a space it selects the run of spaces instead, which is Ply's rule and
/// the one every text field has: double clicking the gap between two words
/// should select something rather than nothing.
pub fn wordAt(text: []const u8, offset: usize) Range {
    const point = @min(offset, text.len);
    if (text.len == 0 or point >= text.len) return .{ .start = point, .end = point };

    const on_space = spaceAt(text, point);
    var start = point;
    while (start > 0 and spaceAt(text, previous(text, start)) == on_space) start = previous(text, start);
    var end = point;
    while (end < text.len and spaceAt(text, end) == on_space) end = next(text, end);
    return .{ .start = start, .end = end };
}

/// The byte offset `count` characters into a string, or its end.
///
/// The bridge between the two ways of counting this file needs. A cursor is a
/// byte offset into the stored text, but what a password *draws* is one
/// bullet per character - three bytes where the character was one - so the
/// only thing the two strings agree on is how many characters in a position
/// is. Everything that has to cross between them goes through here.
pub fn offsetOfCharacter(text: []const u8, count: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    while (seen < count and i < text.len) : (seen += 1) i = next(text, i);
    return i;
}

/// The character boundary nearest a pixel position.
///
/// `positions` is one x per boundary, from the left edge of the first
/// character to the right edge of the last, so it is one longer than the
/// string is characters. Ply builds it the same way and for the same reason:
/// a click lands between two characters, not on one.
pub fn nearestBoundary(x: f32, positions: []const f32) usize {
    if (positions.len == 0) return 0;
    var best: usize = 0;
    var best_distance: f32 = std.math.floatMax(f32);
    for (positions, 0..) |position, i| {
        const distance = @abs(x - position);
        if (distance < best_distance) {
            best_distance = distance;
            best = i;
        }
    }
    return best;
}

// -------------------------------------------------------------------------
// Lines as they are drawn
// -------------------------------------------------------------------------

/// One line of a text input as it appears on screen.
///
/// Offsets are into the **display** text - the bullets rather than the
/// password, the placeholder rather than the empty string - because this is
/// about what is drawn. `offsetOfCharacter` is what crosses back.
pub const VisualLine = struct {
    /// What is drawn: `display[start..end]`.
    start: usize,
    end: usize,
    /// Where the next line begins.
    ///
    /// Not the same as `end`, and the gap is the point: between them lie the
    /// newline that ended the line, or the spaces a wrap swallowed. Neither
    /// is drawn, but the cursor can still be in there - and a line list that
    /// could not say so would put the cursor on the wrong line every time it
    /// sat at the end of a wrapped one.
    next: usize,

    pub inline fn text(self: VisualLine, display_text: []const u8) []const u8 {
        return display_text[self.start..self.end];
    }
};

/// Break the display text into the lines that are drawn.
///
/// A single-line input is always one line however long it gets: it scrolls
/// sideways rather than wrapping, and that is the whole difference between
/// the two modes. A multiline one breaks at every `\n` and then again
/// wherever a word will not fit - unless `width` is zero or less, which means
/// nobody has said how wide it is yet and hard breaks are all there is to go
/// on.
///
/// Ply's `wrap_lines`, built here on the `text.Words` iterator the paragraph
/// wrapper already uses, so a text input and a label break a sentence in the
/// same place.
pub fn wrapLines(
    out: *std.ArrayList(VisualLine),
    gpa: std.mem.Allocator,
    run: []const u8,
    width: f32,
    multiline: bool,
    style: text_mod.TextStyle,
    measurer: text_mod.Measurer,
) std.mem.Allocator.Error![]const VisualLine {
    const first = out.items.len;

    if (!multiline) {
        try out.append(gpa, .{ .start = 0, .end = run.len, .next = run.len });
        return out.items[first..];
    }

    var line_start: usize = 0;
    var line_end: usize = 0;
    var x: f32 = 0;

    var words: text_mod.Words = .init(run, style, measurer);
    while (words.next()) |word| {
        if (word.isBreak()) {
            try out.append(gpa, .{ .start = line_start, .end = line_end, .next = word.start + 1 });
            line_start = word.start + 1;
            line_end = line_start;
            x = 0;
            continue;
        }

        // A word that will not fit starts a new line - unless it is the first
        // word on this one, in which case there is nowhere better for it to
        // go and it overflows. A wrapper without that guard loops for ever on
        // a word wider than the box.
        if (width > 0 and x > 0 and x + word.width > width) {
            try out.append(gpa, .{ .start = line_start, .end = line_end, .next = word.start });
            line_start = word.start;
            x = 0;
        }

        line_end = word.start + word.len;
        x += word.width + word.space;
    }

    try out.append(gpa, .{ .start = line_start, .end = run.len, .next = run.len });
    return out.items[first..];
}

/// Which line an offset is on, and where along it.
///
/// The offset comes back clamped into the drawn part of the line, so a cursor
/// sitting in the space a wrap swallowed is drawn at the end of the text
/// rather than past it.
pub fn locate(lines: []const VisualLine, offset: usize) struct { line: usize, at: usize } {
    if (lines.len == 0) return .{ .line = 0, .at = 0 };
    for (lines, 0..) |line, i| {
        if (offset < line.next or i + 1 == lines.len) {
            return .{ .line = i, .at = std.math.clamp(offset, line.start, line.end) };
        }
    }
    return .{ .line = lines.len - 1, .at = lines[lines.len - 1].end };
}

// -------------------------------------------------------------------------
// The state
// -------------------------------------------------------------------------

/// One snapshot on the undo stack. Owns its copy of the text.
const Undone = struct {
    text: []u8,
    cursor: usize,
    anchor: ?usize,
    kind: EditKind,

    fn deinit(self: *Undone, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
    }
};

/// Everything one text input remembers between frames.
///
/// Kept by `Ui` in a map keyed by element id, next to the scroll positions
/// and for the same reason: it is what the reader has done to the page, and
/// redeclaring the page must not undo it.
pub const TextEdit = struct {
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor, always on a character boundary.
    cursor: usize = 0,
    /// Where a selection started, or null when there is none. The selection
    /// runs between here and the cursor in whichever order they fall, which
    /// is what makes shift-clicking backwards work without a special case.
    anchor: ?usize = null,

    /// How far the text has been moved to keep the cursor in view. Positive
    /// means up and left, as everywhere else in this library.
    scroll: Vec2 = .{ .x = 0, .y = 0 },

    /// Seconds since the cursor was last moved or the text last changed. The
    /// blink is a function of this rather than a toggle, so a cursor that has
    /// just moved is always solid.
    blink: f64 = 0,
    /// The column up and down aim for, in characters.
    ///
    /// **An improvement on Ply**, whose plain path recomputes the column at
    /// every step and so loses it the moment the cursor passes through a
    /// short line. Ply has the field and its comment - "saved visual column
    /// for vertical navigation" - and only its styled path uses it.
    preferred_column: ?usize = null,

    /// When the last click landed and on which element, for spotting a double
    /// click. Zero means there has not been one.
    last_click: f64 = 0,
    last_click_at: usize = 0,

    undo_stack: std.ArrayList(Undone) = .empty,
    redo_stack: std.ArrayList(Undone) = .empty,

    /// Whether `text` is markup. See `Config.markup`.
    markup: bool = false,
    /// The text with the tags taken out - what the reader sees, and what
    /// every position in this type is an offset into.
    ///
    /// Ply solves this the other way: its cursor is a character index into
    /// the stripped text and every one of its editing methods has a second
    /// `_styled` copy that converts on the way in and out, which is about a
    /// thousand lines. Keeping the stripped text beside the raw one instead
    /// means the movement, the selection and the word boundaries are the same
    /// code for both kinds of field, and only the two places that actually
    /// change the string have anything to say about markup.
    ///
    /// Rebuilt from `text` after every edit. Empty when this is not a markup
    /// field, and `shown` is what to read either way.
    visible: std.ArrayList(u8) = .empty,
    /// Where each byte of `visible` came from in `text`, which is what turns
    /// an edit the reader made into an edit of the string.
    marks: std.ArrayList(markup.Mark) = .empty,
    /// How `visible` is coloured, for the drawing, and what moves it.
    spans: std.ArrayList(markup.Span) = .empty,
    effects_list: std.ArrayList(markup.Effect) = .empty,

    /// What the last declaration said.
    ///
    /// Kept here rather than looked up, because an action arrives *between*
    /// frames - the tree it was declared in has been cleared and the next one
    /// has not been built - and both of these change what a key does.
    multiline: bool = false,
    max_length: ?usize = null,

    /// Bumped every time the text actually changes.
    ///
    /// A number rather than a flag because "did that do anything" is asked
    /// after the fact, and comparing two revisions is cheaper and surer than
    /// keeping a copy of the string to compare against - which is what Ply
    /// does, once per keystroke.
    revision: u32 = 0,
    /// Whether the text has changed, and whether Enter has been pressed,
    /// since the last frame started.
    changed: bool = false,
    submitted: bool = false,
    /// The same two as the frame being drawn sees them.
    ///
    /// Doubled, and it has to be. Keys arrive *between* frames, so a flag the
    /// frame cleared when it ended would be gone before anybody could ask -
    /// and one cleared when the frame began would wipe the keystroke that
    /// arrived a moment earlier. `Ui.begin` moves one into the other, which
    /// gives the same answer whether the caller asks while declaring or after
    /// the commands are out.
    changed_this_frame: bool = false,
    submitted_this_frame: bool = false,

    /// Whether the element was declared in the frame just finished. One that
    /// was not is dropped, exactly as a scroll position is.
    live: bool = false,
    /// How long since the text or the cursor last moved, in seconds, and
    /// whether either did this frame. What a scrollbar told to hide itself
    /// reads - the same pair a scroll container keeps, advanced by the same
    /// `Ui.tick`.
    idle: f32 = 0,
    active: bool = false,

    pub const empty: TextEdit = .{};

    /// Fold the pending flags into what this frame answers. Called by
    /// `Ui.begin`, once per frame per input.
    pub fn beginFrame(self: *TextEdit) void {
        self.changed_this_frame = self.changed;
        self.submitted_this_frame = self.submitted;
        self.changed = false;
        self.submitted = false;
    }

    pub fn deinit(self: *TextEdit, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.visible.deinit(gpa);
        self.marks.deinit(gpa);
        self.spans.deinit(gpa);
        self.effects_list.deinit(gpa);
        for (self.undo_stack.items) |*entry| entry.deinit(gpa);
        self.undo_stack.deinit(gpa);
        for (self.redo_stack.items) |*entry| entry.deinit(gpa);
        self.redo_stack.deinit(gpa);
        self.* = undefined;
    }

    /// The string as it is stored, tags and all. What a program reads back.
    pub inline fn value(self: TextEdit) []const u8 {
        return self.text.items;
    }

    /// The text as the reader sees it, which is the same string unless this
    /// is a markup field.
    ///
    /// **Every position in this type is an offset into this** - the cursor,
    /// the anchor, a selection, the answer a click gives. The reader points
    /// at what they can see.
    pub inline fn shown(self: TextEdit) []const u8 {
        return if (self.markup) self.visible.items else self.text.items;
    }

    /// Put the raw string and the view of it back in agreement.
    ///
    /// Called after everything that changes the text. Does nothing at all to
    /// a plain field, which is why the cost of markup is paid only by the
    /// fields that asked for it.
    ///
    /// `visible` is scratch for the compaction on the way through, which is
    /// safe because the next thing that happens to it is being rebuilt from
    /// the result - and it saves a buffer per text input.
    pub fn settle(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (!self.markup) return;

        self.visible.clearRetainingCapacity();
        const tidied = try markup.compact(&self.visible, gpa, self.text.items);
        if (tidied.len != self.text.items.len) {
            self.text.clearRetainingCapacity();
            try self.text.appendSlice(gpa, tidied);
        }

        self.visible.clearRetainingCapacity();
        self.marks.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.effects_list.clearRetainingCapacity();
        _ = try markup.parse(&self.visible, &self.spans, &self.marks, &self.effects_list, gpa, self.text.items);
    }

    /// Where in the raw string an insertion at this visible offset belongs.
    ///
    /// Just after the byte to its left, so typing at the edge of a style
    /// carries on in that style - which is what a word processor does, and it
    /// is the one thing a single cursor position has to choose. Ply gives the
    /// cursor an extra position for every closing brace so it can be on
    /// either side of one; that buys the choice at the price of a right arrow
    /// that sometimes does not appear to move, and this does not.
    ///
    /// What it costs: text that ends inside a style has no position outside
    /// it, so typing at the end goes on being red. Continuing a style while
    /// writing is wanted far more often than escaping one.
    fn rawInsertAt(self: TextEdit, at: usize) usize {
        if (!self.markup) return at;
        if (self.marks.items.len == 0) return self.text.items.len;
        if (at == 0) return self.marks.items[0].start;
        const before = @min(at, self.marks.items.len);
        return self.marks.items[before - 1].end;
    }

    /// The stretch of the raw string a visible range stands for.
    fn rawSpan(self: TextEdit, from: usize, to: usize) markup.Range {
        if (!self.markup) return .{ .start = from, .end = to };
        if (from >= to or from >= self.marks.items.len) return .{ .start = 0, .end = 0 };
        const last = @min(to, self.marks.items.len);
        return .{
            .start = self.marks.items[from].start,
            .end = self.marks.items[last - 1].end,
        };
    }

    /// Take a stretch of what the reader sees out of the string.
    ///
    /// One of the two places markup is anybody's business. Everything above
    /// it works in visible offsets and does not care.
    fn removeVisible(
        self: *TextEdit,
        gpa: std.mem.Allocator,
        from: usize,
        to: usize,
    ) std.mem.Allocator.Error!void {
        if (from >= to) return;
        const raw = self.rawSpan(from, to);
        if (raw.end <= raw.start) return;

        self.text.replaceRange(undefined, raw.start, raw.end - raw.start, "") catch unreachable;
        try self.settle(gpa);
        self.revision +%= 1;
    }

    /// Put text in where the reader is pointing. The other of the two.
    fn insertVisible(
        self: *TextEdit,
        gpa: std.mem.Allocator,
        at: usize,
        run: []const u8,
    ) std.mem.Allocator.Error!void {
        if (run.len == 0) return;
        const where = self.rawInsertAt(at);

        if (self.markup) {
            // Escaped on the way in, or typing a brace would open a tag. The
            // reader typed a brace and should get a brace.
            self.visible.clearRetainingCapacity();
            const escaped = try markup.escape(&self.visible, gpa, run);
            try self.text.insertSlice(gpa, where, escaped);
        } else {
            try self.text.insertSlice(gpa, where, run);
        }

        try self.settle(gpa);
        self.revision +%= 1;
    }

    // -- selection --

    /// The selection in order, or null when there is none. Ply's
    /// `selection_range`.
    pub fn selection(self: TextEdit) ?Range {
        const anchor = self.anchor orelse return null;
        return .{
            .start = @min(anchor, self.cursor),
            .end = @max(anchor, self.cursor),
        };
    }

    /// The selected text, or an empty slice. Borrowed from the buffer, so it
    /// is only good until the next edit.
    pub fn selected(self: TextEdit) []const u8 {
        const range = self.selection() orelse return "";
        return self.shown()[range.start..range.end];
    }

    /// Remove the selection and put the cursor where it started. True when
    /// there was one.
    pub fn deleteSelection(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
        const range = self.selection() orelse return false;
        if (range.empty()) {
            self.anchor = null;
            return false;
        }
        try self.removeVisible(gpa, range.start, range.end);
        self.cursor = range.start;
        self.anchor = null;
        return true;
    }

    // -- editing --

    /// Insert text at the cursor, replacing the selection.
    ///
    /// `max_length` is in characters, and a paste that would run past it is
    /// truncated rather than refused - typing into a full field does nothing,
    /// but pasting a paragraph into a field with four characters left puts
    /// four characters in, which is what every other text field does.
    pub fn insert(
        self: *TextEdit,
        gpa: std.mem.Allocator,
        run: []const u8,
        max_length: ?usize,
    ) std.mem.Allocator.Error!void {
        _ = try self.deleteSelection(gpa);

        var run_to_insert = run;
        if (max_length) |max| {
            const have = characters(self.shown());
            if (have >= max) return;
            const room = max - have;

            var count: usize = 0;
            var i: usize = 0;
            while (i < run.len and count < room) : (count += 1) i = next(run, i);
            run_to_insert = run[0..i];
        }
        if (run_to_insert.len == 0) return;

        try self.insertVisible(gpa, self.cursor, run_to_insert);
        self.cursor += run_to_insert.len;
        self.resetBlink();
    }

    /// Delete the character before the cursor, or the selection.
    pub fn backspace(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        defer self.resetBlink();
        if (try self.deleteSelection(gpa)) return;
        if (self.cursor == 0) return;

        const from = previous(self.shown(), self.cursor);
        try self.removeVisible(gpa, from, self.cursor);
        self.cursor = from;
    }

    /// Delete the character after the cursor, or the selection.
    pub fn deleteForward(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        defer self.resetBlink();
        if (try self.deleteSelection(gpa)) return;
        if (self.cursor >= self.shown().len) return;

        const to = next(self.shown(), self.cursor);
        try self.removeVisible(gpa, self.cursor, to);
    }

    /// Delete back to the start of the word, or the selection.
    pub fn backspaceWord(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        defer self.resetBlink();
        if (try self.deleteSelection(gpa)) return;

        const from = wordLeft(self.shown(), self.cursor);
        if (from == self.cursor) return;
        try self.removeVisible(gpa, from, self.cursor);
        self.cursor = from;
    }

    /// Delete forward over the word and the space after it, or the selection.
    pub fn deleteWordForward(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        defer self.resetBlink();
        if (try self.deleteSelection(gpa)) return;

        const to = wordDeleteRight(self.shown(), self.cursor);
        if (to == self.cursor) return;
        try self.removeVisible(gpa, self.cursor, to);
    }

    // -- movement --

    /// Put the cursor somewhere, and do the right thing with the selection.
    ///
    /// The three lines this factors out are repeated at the top and bottom of
    /// every one of Ply's fifteen movement methods, which is where a port
    /// gets one of them subtly wrong. Written once here: shift starts a
    /// selection if there is not one, no shift drops it, and a selection that
    /// has collapsed onto its own anchor is no selection at all.
    fn moveTo(self: *TextEdit, target: usize, select: bool) void {
        if (select and self.anchor == null) self.anchor = self.cursor;
        self.cursor = target;
        if (!select) {
            self.anchor = null;
        } else if (self.anchor == self.cursor) {
            self.anchor = null;
        }
        self.resetBlink();
    }

    /// Apply a movement. The switch is the whole of Ply's fifteen methods.
    pub fn move(self: *TextEdit, motion: Move) void {
        const body = self.shown();

        // Up and down keep the column they started from; everything else
        // gives it up, so a left arrow between two ups does what it looks
        // like it should.
        switch (motion.to) {
            .up, .down => {},
            else => self.preferred_column = null,
        }

        switch (motion.to) {
            .left => {
                // Without shift, a left arrow on a selection collapses to its
                // start rather than moving - which is one character different
                // from what a naive port does, and is what every text field
                // in the world does.
                if (!motion.select) {
                    if (self.selection()) |range| {
                        self.cursor = range.start;
                        self.anchor = null;
                        self.resetBlink();
                        return;
                    }
                }
                self.moveTo(previous(body, self.cursor), motion.select);
            },
            .right => {
                if (!motion.select) {
                    if (self.selection()) |range| {
                        self.cursor = range.end;
                        self.anchor = null;
                        self.resetBlink();
                        return;
                    }
                }
                self.moveTo(next(body, self.cursor), motion.select);
            },
            .word_left => self.moveTo(wordLeft(body, self.cursor), motion.select),
            .word_right => self.moveTo(wordRight(body, self.cursor), motion.select),
            .start => self.moveTo(
                if (self.multiline) lineStart(body, self.cursor) else 0,
                motion.select,
            ),
            .end => self.moveTo(
                if (self.multiline) lineEnd(body, self.cursor) else body.len,
                motion.select,
            ),
            .text_start => self.moveTo(0, motion.select),
            .text_end => self.moveTo(body.len, motion.select),
            .up, .down => self.moveVertically(motion),
        }
    }

    fn moveVertically(self: *TextEdit, motion: Move) void {
        const body = self.text.items;
        const here = lineAndColumn(body, self.cursor);
        const column = self.preferred_column orelse here.column;

        const target = switch (motion.to) {
            .up => if (here.line == 0) 0 else offsetOfLineColumn(body, here.line - 1, column),
            .down => if (here.line + 1 >= lineCount(body))
                body.len
            else
                offsetOfLineColumn(body, here.line + 1, column),
            else => unreachable,
        };

        // Off the top or the bottom the cursor goes to the very start or end,
        // which is Ply's behaviour and the terminal's. The column is given up
        // there, because there is no line left to keep it for.
        const leaving = (motion.to == .up and here.line == 0) or
            (motion.to == .down and here.line + 1 >= lineCount(body));
        self.preferred_column = if (leaving) null else column;

        self.moveTo(target, motion.select);
    }

    /// Select everything. Does nothing to an empty input, so Ctrl+A in an
    /// empty box does not leave an anchor behind.
    pub fn selectAll(self: *TextEdit) void {
        if (self.shown().len > 0) {
            self.anchor = 0;
            self.cursor = self.shown().len;
        }
        self.resetBlink();
    }

    /// Put the cursor at an offset a click resolved to.
    pub fn clickTo(self: *TextEdit, offset: usize, select: bool) void {
        self.preferred_column = null;
        self.moveTo(@min(offset, self.shown().len), select);
    }

    /// Select the word at an offset. What a double click does.
    pub fn selectWordAt(self: *TextEdit, offset: usize) void {
        const word = wordAt(self.shown(), offset);
        if (!word.empty()) {
            self.anchor = word.start;
            self.cursor = word.end;
        }
        self.preferred_column = null;
        self.resetBlink();
    }

    // -- the cursor itself --

    /// Make the cursor solid again. Called by everything that moves it,
    /// because a cursor that blinks out mid-keystroke looks broken.
    pub inline fn resetBlink(self: *TextEdit) void {
        self.blink = 0;
    }

    /// Whether the cursor is in the on half of its blink. Ply's numbers: a
    /// 1.06 second cycle, on for the first 0.53 of it.
    pub fn cursorVisible(self: TextEdit) bool {
        return @mod(self.blink, 1.06) < 0.53;
    }

    // -- keeping the cursor on screen --

    /// Scroll sideways just enough to show the cursor.
    ///
    /// `cursor_x` is where the cursor is measured from the start of the text,
    /// and `width` is how much of it fits. Both in pixels.
    pub fn revealX(self: *TextEdit, cursor_x: f32, width: f32) void {
        if (cursor_x - self.scroll.x > width) self.scroll.x = cursor_x - width;
        if (cursor_x - self.scroll.x < 0) self.scroll.x = cursor_x;
        if (self.scroll.x < 0) self.scroll.x = 0;
    }

    /// Scroll up or down just enough to show the line the cursor is on.
    pub fn revealY(self: *TextEdit, line: usize, line_height: f32, height: f32) void {
        const top = @as(f32, @floatFromInt(line)) * line_height;
        const bottom = top + line_height;
        if (bottom - self.scroll.y > height) self.scroll.y = bottom - height;
        if (top - self.scroll.y < 0) self.scroll.y = top;
        if (self.scroll.y < 0) self.scroll.y = 0;
    }

    // -- undo --

    /// Save the current state before an edit of this kind.
    ///
    /// Grouping is the whole subtlety. Typing a word should be one undo, so a
    /// second `insert` in a row keeps the entry the first one pushed rather
    /// than adding another - the saved state is from *before* the run, which
    /// is what the reader means by "undo what I just typed".
    pub fn pushUndo(self: *TextEdit, gpa: std.mem.Allocator, kind: EditKind) std.mem.Allocator.Error!void {
        if (kind.groups()) {
            if (self.undo_stack.items.len > 0) {
                const last = self.undo_stack.items[self.undo_stack.items.len - 1];
                if (last.kind == kind) {
                    self.clearRedo(gpa);
                    return;
                }
            }
        }

        const snapshot = try gpa.dupe(u8, self.text.items);
        errdefer gpa.free(snapshot);
        try self.undo_stack.append(gpa, .{
            .text = snapshot,
            .cursor = self.cursor,
            .anchor = self.anchor,
            .kind = kind,
        });

        if (self.undo_stack.items.len > max_undo) {
            var oldest = self.undo_stack.orderedRemove(0);
            oldest.deinit(gpa);
        }
        self.clearRedo(gpa);
    }

    fn clearRedo(self: *TextEdit, gpa: std.mem.Allocator) void {
        for (self.redo_stack.items) |*entry| entry.deinit(gpa);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Step back one edit. True when there was one to step back to.
    pub fn undo(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
        return self.step(gpa, &self.undo_stack, &self.redo_stack);
    }

    /// Step forward again.
    pub fn redo(self: *TextEdit, gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
        return self.step(gpa, &self.redo_stack, &self.undo_stack);
    }

    /// Undo and redo are the same move in opposite directions: pop one stack,
    /// push what is here onto the other, and become what was popped.
    fn step(
        self: *TextEdit,
        gpa: std.mem.Allocator,
        from: *std.ArrayList(Undone),
        onto: *std.ArrayList(Undone),
    ) std.mem.Allocator.Error!bool {
        if (from.items.len == 0) return false;

        const snapshot = try gpa.dupe(u8, self.text.items);
        errdefer gpa.free(snapshot);

        var entry = from.pop().?;
        try onto.append(gpa, .{
            .text = snapshot,
            .cursor = self.cursor,
            .anchor = self.anchor,
            .kind = entry.kind,
        });

        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, entry.text);
        try self.settle(gpa);
        self.revision +%= 1;
        self.cursor = @min(entry.cursor, self.shown().len);
        self.anchor = if (entry.anchor) |anchor| @min(anchor, self.shown().len) else null;
        entry.deinit(gpa);

        self.resetBlink();
        return true;
    }

    // -- setting it from the program --

    /// Replace the text, as `Ui.setTextValue` does.
    ///
    /// Clamps the cursor and drops the selection rather than leaving either
    /// pointing into a string that is no longer there. Does not push an undo,
    /// because the program setting a field is not an edit the reader made.
    pub fn setValue(self: *TextEdit, gpa: std.mem.Allocator, run: []const u8) std.mem.Allocator.Error!void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, run);
        try self.settle(gpa);
        self.revision +%= 1;
        self.cursor = @min(self.cursor, self.shown().len);
        self.anchor = null;
        self.preferred_column = null;
        self.resetBlink();
    }
};

/// What is drawn rather than what is stored: the placeholder when the text is
/// empty, a row of bullets when it is a password, the text otherwise.
///
/// Appended to `out` and returned from it, because a password is not a slice
/// of anything - it is one bullet per character of a string nobody may see,
/// and it has to be built somewhere.
pub fn display(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    text: []const u8,
    placeholder: []const u8,
    password: bool,
) std.mem.Allocator.Error![]const u8 {
    const start = out.items.len;
    if (text.len == 0) {
        try out.appendSlice(gpa, placeholder);
    } else if (password) {
        var i: usize = 0;
        while (i < text.len) : (i = next(text, i)) try out.appendSlice(gpa, bullet);
    } else {
        try out.appendSlice(gpa, text);
    }
    return out.items[start..];
}

/// Where every character boundary of a run sits, measured from its start.
///
/// One more entry than there are characters: the first is always zero and the
/// last is the width of the whole run. Ply's `compute_char_x_positions`, and
/// it is quadratic for the same reason - each boundary is the width of the
/// prefix up to it, and a measurer that has kerning cannot be asked for
/// anything cheaper without lying about it.
pub fn boundaries(
    out: *std.ArrayList(f32),
    gpa: std.mem.Allocator,
    run: []const u8,
    style: text_mod.TextStyle,
    measurer: text_mod.Measurer,
) std.mem.Allocator.Error![]const f32 {
    const start = out.items.len;
    try out.append(gpa, 0);

    var i: usize = 0;
    while (i < run.len) {
        i = next(run, i);
        try out.append(gpa, measurer.measure(run[0..i], style).width);
    }
    return out.items[start..];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// Everything below runs on a string and two numbers. There is no `Ui`, no
// measurer and no window in this section, which is the point of keeping the
// model separate from the drawing: a rule about where Ctrl+Left goes can be
// stated and checked in four lines.

/// A `TextEdit` holding this text, cursor at the end.
fn edit(gpa: std.mem.Allocator, text: []const u8) !TextEdit {
    var state: TextEdit = .empty;
    try state.text.appendSlice(gpa, text);
    state.cursor = state.text.items.len;
    return state;
}

test "walking UTF-8 goes by character, not by byte" {
    // Hungarian, because it is the language of the person reading this and
    // because "ű" is two bytes where "u" is one.
    const word = "árvíztűrő";
    try testing.expectEqual(@as(usize, 9), characters(word));
    try testing.expectEqual(@as(usize, 13), word.len);

    // Forwards and back over the whole thing lands on the same boundaries.
    var forwards: [10]usize = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i <= word.len) : (count += 1) {
        forwards[count] = i;
        if (i == word.len) break;
        i = next(word, i);
    }
    try testing.expectEqual(@as(usize, 10), count + 1);

    var back = word.len;
    var seen: usize = count;
    while (back > 0) {
        try testing.expectEqual(forwards[seen], back);
        back = previous(word, back);
        seen -= 1;
    }
}

test "a stray continuation byte does not walk off the front" {
    // Invalid UTF-8 is what a paste from somewhere else looks like, and an
    // editor that panics on it is worse than one that shows mojibake.
    const broken = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 };
    try testing.expectEqual(@as(usize, 2), previous(&broken, 6));
    try testing.expectEqual(@as(usize, 1), next(&broken, 0));
}

test "word boundaries are Ply's three, and they are three for a reason" {
    const line = "hello  world again";
    //           0123456789...

    // Left: back over spaces, then back over the word.
    try testing.expectEqual(@as(usize, 7), wordLeft(line, 12));
    try testing.expectEqual(@as(usize, 0), wordLeft(line, 7));

    // Right: forward over spaces, then to the end of the word.
    try testing.expectEqual(@as(usize, 12), wordRight(line, 5));
    try testing.expectEqual(@as(usize, 5), wordRight(line, 0));

    // Delete right: the word *then* the spaces, so removing "hello" from the
    // front does not leave two spaces behind. This is the one that differs.
    try testing.expectEqual(@as(usize, 7), wordDeleteRight(line, 0));
}

test "double clicking a gap selects the gap" {
    const line = "hello  world";
    const word = wordAt(line, 1);
    try testing.expectEqual(@as(usize, 0), word.start);
    try testing.expectEqual(@as(usize, 5), word.end);

    // On a space, the run of spaces - because selecting nothing would look
    // like the click did not register.
    const gap = wordAt(line, 5);
    try testing.expectEqual(@as(usize, 5), gap.start);
    try testing.expectEqual(@as(usize, 7), gap.end);
}

test "a non-breaking space is a space to word movement" {
    // The character somebody pastes in without knowing. ASCII-only word
    // movement walks straight through it and selects both words at once.
    const line = "one\u{00A0}two";
    try testing.expectEqual(@as(usize, 0), wordAt(line, 0).start);
    try testing.expectEqual(@as(usize, 3), wordAt(line, 0).end);
}

test "lines and columns are counted in characters" {
    const body = "egy\nkettő\nhárom";
    try testing.expectEqual(@as(usize, 3), lineCount(body));

    const second = lineAndColumn(body, 8); // inside "kettő"
    try testing.expectEqual(@as(usize, 1), second.line);
    try testing.expectEqual(@as(usize, 4), second.column);

    // And back again, which is what up and down are built on.
    try testing.expectEqual(@as(usize, 8), offsetOfLineColumn(body, 1, 4));

    // A column past the end of a line clamps to that line's end rather than
    // running into the next one.
    try testing.expectEqual(@as(usize, 3), offsetOfLineColumn(body, 0, 40));
}

test "typing inserts at the cursor and pushes it along" {
    var state = try edit(testing.allocator, "hell");
    defer state.deinit(testing.allocator);

    try state.insert(testing.allocator, "o", null);
    try testing.expectEqualStrings("hello", state.value());
    try testing.expectEqual(@as(usize, 5), state.cursor);
}

test "a length limit is counted in characters and truncates a paste" {
    var state = try edit(testing.allocator, "árv");
    defer state.deinit(testing.allocator);

    // Three characters in four bytes, and a limit of five characters: two of
    // the three pasted fit, and the third is dropped rather than the whole
    // paste being refused.
    try state.insert(testing.allocator, "ízt", 5);
    try testing.expectEqualStrings("árvíz", state.value());
    try testing.expectEqual(@as(usize, 5), characters(state.value()));
    // Seven bytes for five characters - two of them are accented - and it is
    // the character count the limit is about.
    try testing.expectEqual(@as(usize, 7), state.value().len);

    // A full field takes nothing at all.
    try state.insert(testing.allocator, "!", 5);
    try testing.expectEqualStrings("árvíz", state.value());
}

test "backspace and delete step by character" {
    var state = try edit(testing.allocator, "tűz");
    defer state.deinit(testing.allocator);

    try state.backspace(testing.allocator);
    try testing.expectEqualStrings("tű", state.value());
    // One backspace took the whole two-byte "ű", not half of it.
    try state.backspace(testing.allocator);
    try testing.expectEqualStrings("t", state.value());

    state.cursor = 0;
    try state.deleteForward(testing.allocator);
    try testing.expectEqualStrings("", state.value());
}

test "typing over a selection replaces it" {
    var state = try edit(testing.allocator, "hello world");
    defer state.deinit(testing.allocator);

    state.anchor = 6;
    state.cursor = 11;
    try testing.expectEqualStrings("world", state.selected());

    try state.insert(testing.allocator, "there", null);
    try testing.expectEqualStrings("hello there", state.value());
    try testing.expect(state.anchor == null);
}

test "shift extends a selection and moving without it collapses to an end" {
    var state = try edit(testing.allocator, "hello");
    defer state.deinit(testing.allocator);
    state.cursor = 0;

    state.move(.{ .to = .right, .select = true });
    state.move(.{ .to = .right, .select = true });
    try testing.expectEqualStrings("he", state.selected());

    // Left without shift goes to the *start* of the selection and does not
    // move a character further, which is the rule a naive port gets wrong.
    state.move(.{ .to = .left });
    try testing.expectEqual(@as(usize, 0), state.cursor);
    try testing.expect(state.anchor == null);
}

test "a selection dragged back onto its own anchor is no selection" {
    var state = try edit(testing.allocator, "hello");
    defer state.deinit(testing.allocator);
    state.cursor = 2;

    state.move(.{ .to = .right, .select = true });
    try testing.expect(state.selection() != null);
    state.move(.{ .to = .left, .select = true });
    try testing.expect(state.selection() == null);
}

test "up and down keep the column they started from" {
    // Ply recomputes the column at every step, so passing through a short
    // line forgets it. This is the one place the port deliberately does
    // better, and this is what it buys.
    // A long line, a short one, a long one. Accented letters throughout,
    // because a column is in characters and the bytes are not the same
    // number - which is exactly the arithmetic this is here to pin down.
    var state = try edit(testing.allocator, "hosszú sor\nrövid\nmásik hosszú sor");
    defer state.deinit(testing.allocator);

    const column = struct {
        fn of(u: TextEdit) usize {
            return lineAndColumn(u.value(), u.cursor).column;
        }
    }.of;

    // Column eight of the first line, said in columns rather than in bytes.
    state.cursor = offsetOfLineColumn(state.value(), 0, 8);
    try testing.expectEqual(@as(usize, 8), column(state));

    // Down onto "rövid", which is only five characters, so the cursor lands
    // at its end.
    state.move(.{ .to = .down });
    try testing.expectEqual(@as(usize, 5), column(state));

    // Down again: back out to column eight, not stuck at five. This is the
    // assertion that fails against Ply's plain path.
    state.move(.{ .to = .down });
    try testing.expectEqual(@as(usize, 8), column(state));

    // A sideways move gives the remembered column up, as it should - so the
    // next up starts from where the cursor actually is.
    state.move(.{ .to = .left });
    state.move(.{ .to = .up });
    try testing.expectEqual(@as(usize, 5), column(state));
}

test "up on the first line goes to the very start" {
    var state = try edit(testing.allocator, "one\ntwo");
    defer state.deinit(testing.allocator);
    state.cursor = 2;

    state.move(.{ .to = .up });
    try testing.expectEqual(@as(usize, 0), state.cursor);

    state.cursor = 5;
    state.move(.{ .to = .down });
    try testing.expectEqual(state.value().len, state.cursor);
}

test "home and end are the line's in a multiline input and the text's otherwise" {
    var state = try edit(testing.allocator, "one\ntwo\nthree");
    defer state.deinit(testing.allocator);
    state.multiline = true;
    state.cursor = 5;

    // The same key, the same action, and the mode decides - so a program
    // binds Home once and it is right in both kinds of field.
    state.move(.{ .to = .start });
    try testing.expectEqual(@as(usize, 4), state.cursor);
    state.move(.{ .to = .end });
    try testing.expectEqual(@as(usize, 7), state.cursor);

    // Ctrl+Home and Ctrl+End reach past the line either way.
    state.move(.{ .to = .text_start });
    try testing.expectEqual(@as(usize, 0), state.cursor);
    state.move(.{ .to = .text_end });
    try testing.expectEqual(state.value().len, state.cursor);

    // The same text in a single-line field: Home is the very start.
    state.multiline = false;
    state.cursor = 5;
    state.move(.{ .to = .start });
    try testing.expectEqual(@as(usize, 0), state.cursor);
}

test "deleting a word forward takes the space after it" {
    var state = try edit(testing.allocator, "one two three");
    defer state.deinit(testing.allocator);
    state.cursor = 0;

    try state.deleteWordForward(testing.allocator);
    try testing.expectEqualStrings("two three", state.value());

    // And backwards does not, because the space is behind the cursor either
    // way and taking it would eat the previous word's edge.
    state.cursor = state.value().len;
    try state.backspaceWord(testing.allocator);
    try testing.expectEqualStrings("two ", state.value());
}

test "typing a word is one undo, and pasting is its own" {
    var state: TextEdit = .empty;
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;

    for ("abc") |letter| {
        try state.pushUndo(gpa, .insert);
        try state.insert(gpa, &.{letter}, null);
    }
    try testing.expectEqualStrings("abc", state.value());

    try state.pushUndo(gpa, .paste);
    try state.insert(gpa, "XYZ", null);
    try testing.expectEqualStrings("abcXYZ", state.value());

    // One undo takes the paste; the next takes the whole typed run, not one
    // letter of it.
    try testing.expect(try state.undo(gpa));
    try testing.expectEqualStrings("abc", state.value());
    try testing.expect(try state.undo(gpa));
    try testing.expectEqualStrings("", state.value());
    try testing.expect(!try state.undo(gpa));
}

test "redo puts back what undo took, and a new edit throws it away" {
    var state: TextEdit = .empty;
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;

    try state.pushUndo(gpa, .paste);
    try state.insert(gpa, "hello", null);
    try testing.expect(try state.undo(gpa));
    try testing.expectEqualStrings("", state.value());

    try testing.expect(try state.redo(gpa));
    try testing.expectEqualStrings("hello", state.value());

    try testing.expect(try state.undo(gpa));
    try state.pushUndo(gpa, .paste);
    try state.insert(gpa, "other", null);
    // The branch that was undone is gone: there is nothing to redo onto.
    try testing.expect(!try state.redo(gpa));
}

test "the undo stack does not grow without bound" {
    var state: TextEdit = .empty;
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;

    // Alternating kinds, so nothing groups and every one pushes.
    for (0..max_undo + 50) |i| {
        try state.pushUndo(gpa, if (i % 2 == 0) .paste else .cut);
        try state.insert(gpa, "x", null);
    }
    try testing.expectEqual(@as(usize, max_undo), state.undo_stack.items.len);
}

test "the cursor blinks on Ply's clock" {
    var state: TextEdit = .empty;
    defer state.deinit(testing.allocator);

    try testing.expect(state.cursorVisible());
    state.blink = 0.6;
    try testing.expect(!state.cursorVisible());
    state.blink = 1.1;
    try testing.expect(state.cursorVisible());

    // Anything that moves the cursor makes it solid again, so it is never
    // invisible at the moment the reader is looking for it.
    state.blink = 0.6;
    state.move(.{ .to = .left });
    try testing.expect(state.cursorVisible());
}

test "scrolling reveals the cursor from either edge" {
    var state: TextEdit = .empty;
    defer state.deinit(testing.allocator);

    // Off the right: bring it just inside.
    state.revealX(250, 100);
    try testing.expectEqual(@as(f32, 150), state.scroll.x);
    // Off the left: bring it to the left edge.
    state.revealX(20, 100);
    try testing.expectEqual(@as(f32, 20), state.scroll.x);
    // Already inside: leave it alone.
    state.revealX(60, 100);
    try testing.expectEqual(@as(f32, 20), state.scroll.x);

    state.revealY(4, 20, 60);
    try testing.expectEqual(@as(f32, 40), state.scroll.y);
    state.revealY(0, 20, 60);
    try testing.expectEqual(@as(f32, 0), state.scroll.y);
}

test "a password is drawn as bullets, one per character" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    const shown = try display(&out, testing.allocator, "tűz", "", true);
    try testing.expectEqualStrings(bullet ** 3, shown);
    // Three characters, not four - the two-byte "ű" is one bullet.
    try testing.expectEqual(@as(usize, 3), characters(shown));

    out.clearRetainingCapacity();
    const placeholder = try display(&out, testing.allocator, "", "Name", false);
    try testing.expectEqualStrings("Name", placeholder);
}

test "boundaries are one longer than the string is characters" {
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(testing.allocator);

    const measurer: text_mod.Measurer = .monospace(0.5, 1.0);
    const style: text_mod.TextStyle = .{ .font_size = 16 };
    const found = try boundaries(&out, testing.allocator, "abc", style, measurer);

    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqual(@as(f32, 0), found[0]);
    try testing.expectEqual(@as(f32, 8), found[1]);
    try testing.expectEqual(@as(f32, 24), found[3]);

    // And a click lands on the nearest of them.
    try testing.expectEqual(@as(usize, 0), nearestBoundary(3, found));
    try testing.expectEqual(@as(usize, 1), nearestBoundary(5, found));
    try testing.expectEqual(@as(usize, 3), nearestBoundary(1000, found));
}

test "a single-line input is one line however long it gets" {
    var lines: std.ArrayList(VisualLine) = .empty;
    defer lines.deinit(testing.allocator);

    const measurer: text_mod.Measurer = .monospace(0.5, 1.0);
    const style: text_mod.TextStyle = .{ .font_size = 16 };
    const run = "a very long piece of text that would wrap in a paragraph";

    const found = try wrapLines(&lines, testing.allocator, run, 40, false, style, measurer);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(run.len, found[0].end);
}

test "a multiline input breaks at newlines and then at words" {
    var lines: std.ArrayList(VisualLine) = .empty;
    defer lines.deinit(testing.allocator);

    const measurer: text_mod.Measurer = .monospace(0.5, 1.0);
    const style: text_mod.TextStyle = .{ .font_size = 16 };
    // Eight pixels a character, so a forty pixel box holds five of them.
    const found = try wrapLines(&lines, testing.allocator, "one two\nthree", 40, true, style, measurer);

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("one", found[0].text("one two\nthree"));
    try testing.expectEqualStrings("two", found[1].text("one two\nthree"));
    try testing.expectEqualStrings("three", found[2].text("one two\nthree"));

    // The space the wrap swallowed is between one line's end and the next
    // line's start, which is what lets the cursor sit in it.
    try testing.expectEqual(@as(usize, 3), found[0].end);
    try testing.expectEqual(@as(usize, 4), found[0].next);
}

test "an indented line is one line, spaces and all" {
    // The spaces before a line's first word are a zero-length word, like a
    // newline, and were once taken for one: the first space broke the line.
    var lines: std.ArrayList(VisualLine) = .empty;
    defer lines.deinit(testing.allocator);

    const measurer: text_mod.Measurer = .monospace(0.5, 1.0);
    const style: text_mod.TextStyle = .{ .font_size = 16 };
    const run = "  one\n  two";
    const found = try wrapLines(&lines, testing.allocator, run, 400, true, style, measurer);

    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("  one", found[0].text(run));
    try testing.expectEqualStrings("  two", found[1].text(run));
    // A cursor between the two spaces is on the first line, not a line of
    // its own.
    try testing.expectEqual(@as(usize, 0), locate(found, 1).line);
}

test "a word wider than the box overflows instead of looping" {
    var lines: std.ArrayList(VisualLine) = .empty;
    defer lines.deinit(testing.allocator);

    const measurer: text_mod.Measurer = .monospace(0.5, 1.0);
    const style: text_mod.TextStyle = .{ .font_size = 16 };
    const found = try wrapLines(&lines, testing.allocator, "antidisestablishmentarianism", 20, true, style, measurer);

    try testing.expectEqual(@as(usize, 1), found.len);
}

test "an offset in the gap a wrap swallowed belongs to the line before it" {
    var lines: std.ArrayList(VisualLine) = .empty;
    defer lines.deinit(testing.allocator);

    const measurer: text_mod.Measurer = .monospace(0.5, 1.0);
    const style: text_mod.TextStyle = .{ .font_size = 16 };
    const found = try wrapLines(&lines, testing.allocator, "one two", 40, true, style, measurer);
    try testing.expectEqual(@as(usize, 2), found.len);

    // Offset three is the end of "one"; offset four is the start of "two".
    // The space between them is line zero's, and the cursor there draws at
    // the end of "one" rather than floating past it.
    try testing.expectEqual(@as(usize, 0), locate(found, 3).line);
    try testing.expectEqual(@as(usize, 3), locate(found, 3).at);
    try testing.expectEqual(@as(usize, 1), locate(found, 4).line);

    // Past the end lands on the last line, not out of bounds.
    try testing.expectEqual(@as(usize, 1), locate(found, 999).line);
}

test "character offsets cross between the text and what is drawn" {
    // The one conversion a password needs: three characters of stored text,
    // three bullets of nine bytes, and position two in one is position two in
    // the other however many bytes that is.
    const stored = "tűz";
    const drawn = bullet ** 3;

    try testing.expectEqual(@as(usize, 3), offsetOfCharacter(stored, 2));
    try testing.expectEqual(@as(usize, 6), offsetOfCharacter(drawn, 2));
    // And past the end clamps rather than running off.
    try testing.expectEqual(stored.len, offsetOfCharacter(stored, 99));
}

test "setting the value from the program clamps the cursor" {
    var state = try edit(testing.allocator, "a long piece of text");
    defer state.deinit(testing.allocator);
    state.anchor = 2;

    try state.setValue(testing.allocator, "hi");
    try testing.expectEqualStrings("hi", state.value());
    try testing.expectEqual(@as(usize, 2), state.cursor);
    try testing.expect(state.anchor == null);
}

// -------------------------------------------------------------------------
// Editing markup
// -------------------------------------------------------------------------

// A markup field holds the string with the tags in and shows the reader the
// string without them. Every position below is an offset into what they see,
// which is the whole point: the tags are not in their way.

/// A markup `TextEdit` holding this raw string, cursor at the end.
fn styled(gpa: std.mem.Allocator, raw: []const u8) !TextEdit {
    var state: TextEdit = .empty;
    state.markup = true;
    try state.text.appendSlice(gpa, raw);
    try state.settle(gpa);
    state.cursor = state.shown().len;
    return state;
}

test "the cursor moves through the text, not through the tags" {
    var state = try styled(testing.allocator, "a{color=red|bc}d");
    defer state.deinit(testing.allocator);

    try testing.expectEqualStrings("abcd", state.shown());
    try testing.expectEqualStrings("a{color=red|bc}d", state.value());
    try testing.expectEqual(@as(usize, 4), state.cursor);

    // Four characters, four steps - the eleven bytes of tag are not stops
    // along the way.
    var steps: usize = 0;
    while (state.cursor > 0) : (steps += 1) state.move(.{ .to = .left });
    try testing.expectEqual(@as(usize, 4), steps);
}

test "typing inside a style stays in it" {
    var state = try styled(testing.allocator, "a{color=red|bc}d");
    defer state.deinit(testing.allocator);

    // Between b and c.
    state.cursor = 2;
    try state.insert(testing.allocator, "X", null);
    try testing.expectEqualStrings("a{color=red|bXc}d", state.value());
    try testing.expectEqualStrings("abXcd", state.shown());
    try testing.expectEqual(@as(usize, 3), state.cursor);
}

test "typing at the end of a style carries on in it" {
    // The one thing a single cursor position has to choose, and it inherits
    // from the left as a word processor does. Ply has an extra position for
    // every closing brace so it can be on either side.
    var state = try styled(testing.allocator, "{color=red|ab}c");
    defer state.deinit(testing.allocator);

    state.cursor = 2; // between b and c
    try state.insert(testing.allocator, "X", null);
    try testing.expectEqualStrings("{color=red|abX}c", state.value());
}

test "a style at the end of the text goes on being typed in" {
    // The other half of inheriting from the left, and the price of it: text
    // that ends inside a style has no cursor position outside that style, so
    // carrying on typing carries on red. Continuing a style while writing is
    // wanted far more often than escaping one, and escaping is what choosing
    // a different style is for - which is a thing to add, not a reason to
    // give the cursor two places to be.
    var state = try styled(testing.allocator, "{color=red|ab}");
    defer state.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), state.cursor);
    try state.insert(testing.allocator, "X", null);
    try testing.expectEqualStrings("{color=red|abX}", state.value());

    // Where the text ends outside one, it stays outside.
    var after = try styled(testing.allocator, "{color=red|ab}c");
    defer after.deinit(testing.allocator);
    try after.insert(testing.allocator, "X", null);
    try testing.expectEqualStrings("{color=red|ab}cX", after.value());
}

test "typing a brace types a brace" {
    var state = try styled(testing.allocator, "");
    defer state.deinit(testing.allocator);

    try state.insert(testing.allocator, "{color=red|", null);
    // Stored escaped, so it is text and not the start of a tag.
    try testing.expectEqualStrings("\\{color=red\\|", state.value());
    try testing.expectEqualStrings("{color=red|", state.shown());
}

test "backspace over an escaped character takes its backslash too" {
    var state = try styled(testing.allocator, "a\\{b");
    defer state.deinit(testing.allocator);

    try testing.expectEqualStrings("a{b", state.shown());
    state.cursor = 2; // after the brace
    try state.backspace(testing.allocator);

    try testing.expectEqualStrings("ab", state.shown());
    // And not "a\b", which is what deleting one raw byte would leave.
    try testing.expectEqualStrings("ab", state.value());
}

test "deleting a whole styled run takes the tag with it" {
    var state = try styled(testing.allocator, "a{color=red|bc}d");
    defer state.deinit(testing.allocator);

    state.anchor = 1;
    state.cursor = 3;
    try testing.expectEqualStrings("bc", state.selected());
    try testing.expect(try state.deleteSelection(testing.allocator));

    // The tag had nothing left in it, so it is gone rather than left behind
    // as a ghost for the next edit to fall into.
    try testing.expectEqualStrings("ad", state.value());
    try testing.expectEqualStrings("ad", state.shown());
}

test "a selection that spans a tag boundary deletes cleanly" {
    var state = try styled(testing.allocator, "ab{color=red|cd}ef");
    defer state.deinit(testing.allocator);

    state.anchor = 1;
    state.cursor = 5;
    try testing.expectEqualStrings("bcde", state.selected());
    try testing.expect(try state.deleteSelection(testing.allocator));

    try testing.expectEqualStrings("af", state.shown());
    try testing.expectEqualStrings("af", state.value());
}

test "word movement and selection work on what the reader sees" {
    var state = try styled(testing.allocator, "one {color=red|two} three");
    defer state.deinit(testing.allocator);

    try testing.expectEqualStrings("one two three", state.shown());

    state.cursor = 0;
    state.move(.{ .to = .word_right });
    try testing.expectEqual(@as(usize, 3), state.cursor);
    state.move(.{ .to = .word_right });
    try testing.expectEqual(@as(usize, 7), state.cursor);

    // A double click in the middle of the styled word selects the word, not
    // the tag around it.
    state.selectWordAt(5);
    try testing.expectEqualStrings("two", state.selected());
}

test "undo puts the tags back as they were" {
    var state = try styled(testing.allocator, "{color=red|abc}");
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;

    state.anchor = 0;
    state.cursor = 3;
    try state.pushUndo(gpa, .cut);
    _ = try state.deleteSelection(gpa);
    try testing.expectEqualStrings("", state.value());

    try testing.expect(try state.undo(gpa));
    try testing.expectEqualStrings("{color=red|abc}", state.value());
    try testing.expectEqualStrings("abc", state.shown());
}

test "the colours a field draws come out of its own text" {
    var state = try styled(testing.allocator, "a{color=red|bc}d");
    defer state.deinit(testing.allocator);

    // Three spans over "abcd", and only the middle one is coloured.
    try testing.expectEqual(@as(usize, 3), state.spans.items.len);
    try testing.expect(state.spans.items[0].color == null);
    try testing.expect(state.spans.items[1].color != null);
    try testing.expectEqualStrings("bc", state.shown()[state.spans.items[1].start..state.spans.items[1].end]);
}

test "a length limit counts what the reader sees" {
    var state = try styled(testing.allocator, "{color=red|abc}");
    defer state.deinit(testing.allocator);

    // Three visible characters in fifteen bytes. A limit of four leaves room
    // for one more, not for none.
    try state.insert(testing.allocator, "de", 4);
    try testing.expectEqualStrings("abcd", state.shown());
}

test "a plain field is untouched by any of this" {
    // The refactor that made markup possible runs through every edit, so the
    // plain path needs saying out loud: no second buffer, no parsing, and the
    // string it holds is the string it shows.
    var state = try edit(testing.allocator, "{color=red|not markup}");
    defer state.deinit(testing.allocator);

    try testing.expectEqualStrings("{color=red|not markup}", state.shown());
    try testing.expectEqual(@as(usize, 0), state.visible.items.len);
    try testing.expectEqual(@as(usize, 0), state.marks.items.len);

    try state.backspace(testing.allocator);
    try testing.expectEqualStrings("{color=red|not markup", state.value());
}
