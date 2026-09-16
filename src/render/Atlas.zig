// SPDX-License-Identifier: BSD-2-Clause

//! Every glyph the program has drawn, in one texture.
//!
//! A renderer cannot upload a glyph per draw call: a paragraph is a few
//! hundred of them, and a texture switch between each would be a few hundred
//! draw calls for one line of prose. So each glyph is rasterised once, packed
//! into a shared image, and drawn from there for the life of the program -
//! which turns the whole of a frame's text into one instanced draw.
//!
//! **Keyed by face, glyph and size together.** The same letter at 12 pixels
//! and at 13 is two different pictures, and there is no scaling one into the
//! other that does not look wrong. A UI that uses four sizes ends up with
//! four copies of its alphabet, which is a few hundred kilobytes and worth
//! it. And glyph 43 of one font is not glyph 43 of another, so the face is in
//! the key too - as the slot it has in the renderer's table, which is also
//! what a face that changed is forgotten by.
//!
//! Packed on shelves: a row is opened as tall as the first glyph put in it,
//! filled left to right, and closed when the next glyph will not fit. Not the
//! tightest packing there is - a proper rectangle packer wastes less - and it
//! is the right one here, because glyphs of one size are all nearly the same
//! height and a shelf of them has almost no gap in it.
//!
//! ```zig
//! var atlas: Atlas = try .init(gpa, 1024, 1024);
//! defer atlas.deinit();
//!
//! const entry = try atlas.glyph(&face, 0, face.glyphFor('H'), 16);
//! // entry.u0, entry.v0, entry.u1, entry.v1 are where it is in the texture.
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const font = @import("fluxion_font");

const Atlas = @This();

pub const Error = error{
    /// The atlas is full. A bigger one, or a program that draws fewer sizes.
    AtlasFull,
} || Allocator.Error || font.Font.Error;

/// Where one glyph ended up, and what a renderer needs to place it.
pub const Entry = struct {
    /// The corners of it in the texture, from zero to one.
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    /// How big it is, in pixels.
    width: u32,
    height: u32,
    /// How far right of the pen the picture starts.
    left: i32,
    /// How far above the baseline its top row is.
    top: i32,
    /// How far the pen moves afterwards.
    advance: f32,

    /// Whether there is anything to draw. A space has an advance and no
    /// picture, and a renderer that does not check draws a zero-sized quad
    /// for every one of them.
    pub inline fn isBlank(self: Entry) bool {
        return self.width == 0 or self.height == 0;
    }
};

/// A glyph of a face at a size. All three, because they have to be.
pub const Key = struct {
    /// Which face, as its slot in the renderer's table.
    face: u16,
    glyph: u16,
    size: u16,
};

/// One pixel of padding around every glyph.
///
/// Without it, a bilinear sample at the edge of one glyph reaches into the
/// next and text grows faint haloes of its neighbours - which looks like a
/// rasteriser bug and is a packing one.
const padding: u32 = 1;

gpa: Allocator,
/// Coverage, one byte a pixel. Uploaded as `r8_unorm`.
pixels: []u8,
width: u32,
height: u32,

/// Where the next glyph goes, and how tall the shelf it goes on is.
pen_x: u32 = padding,
pen_y: u32 = padding,
shelf_height: u32 = 0,

entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,

/// Whether anything has been added since the texture was last uploaded. A
/// renderer uploads when this is set and clears it - see `markClean`.
dirty: bool = false,

pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Atlas {
    const pixels = try gpa.alloc(u8, width * height);
    @memset(pixels, 0);
    return .{ .gpa = gpa, .pixels = pixels, .width = width, .height = height };
}

pub fn deinit(self: *Atlas) void {
    self.gpa.free(self.pixels);
    self.entries.deinit(self.gpa);
    self.* = undefined;
}

/// Where a glyph is, rasterising and packing it if this is the first time.
///
/// `slot` is which face this is, and is part of the key: the atlas never
/// compares fonts, so two faces given the same slot share their glyphs.
///
/// The size is in whole pixels per em. Rounding it here rather than at the
/// call site is deliberate: a layout that animates a font size through
/// fractional values would otherwise fill the atlas with a hundred nearly
/// identical alphabets.
pub fn glyph(self: *Atlas, face: *const font.Font, slot: u16, index: u16, size: u16) Error!Entry {
    const key: Key = .{ .face = slot, .glyph = index, .size = size };
    if (self.entries.get(key)) |found| return found;

    var rendered = try face.render(self.gpa, index, face.scaleFor(@floatFromInt(size)));
    defer rendered.deinit(self.gpa);

    const entry = try self.place(rendered);
    try self.entries.put(self.gpa, key, entry);
    return entry;
}

/// Find room for a rasterised glyph and copy it in.
fn place(self: *Atlas, rendered: font.Font.Rendered) Error!Entry {
    const w = rendered.bitmap.width;
    const h = rendered.bitmap.height;

    // A space, or anything else with an advance and no picture. It still
    // needs an entry - the advance is on it - but it takes no room.
    if (w == 0 or h == 0) {
        return .{
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
            .width = 0,
            .height = 0,
            .left = rendered.left,
            .top = rendered.top,
            .advance = rendered.advance,
        };
    }

    if (w + padding * 2 > self.width) return error.AtlasFull;

    // Off the end of this shelf: start another below it.
    if (self.pen_x + w + padding > self.width) {
        self.pen_x = padding;
        self.pen_y += self.shelf_height + padding;
        self.shelf_height = 0;
    }
    if (self.pen_y + h + padding > self.height) return error.AtlasFull;

    const x = self.pen_x;
    const y = self.pen_y;

    for (0..h) |row| {
        const source = rendered.bitmap.row(@intCast(row));
        const target = self.pixels[(y + row) * self.width + x ..][0..w];
        @memcpy(target, source);
    }

    self.pen_x += w + padding;
    self.shelf_height = @max(self.shelf_height, h);
    self.dirty = true;

    const width: f32 = @floatFromInt(self.width);
    const height: f32 = @floatFromInt(self.height);
    return .{
        .u0 = @as(f32, @floatFromInt(x)) / width,
        .v0 = @as(f32, @floatFromInt(y)) / height,
        .u1 = @as(f32, @floatFromInt(x + w)) / width,
        .v1 = @as(f32, @floatFromInt(y + h)) / height,
        .width = w,
        .height = h,
        .left = rendered.left,
        .top = rendered.top,
        .advance = rendered.advance,
    };
}

/// How many glyphs are in it.
pub inline fn count(self: Atlas) u32 {
    return self.entries.count();
}

/// Forget every glyph of one face, so each is rasterised again the next time
/// it is asked for - from whatever the face in that slot is by then.
///
/// **The room they took is not given back.** Shelves cannot be packed again
/// around a hole, so the pixels stay where they are until `clear` starts the
/// atlas over. Forgetting is for the rare thing, a font swapped or read again
/// in place, and a renderer that runs out of room clears.
pub fn forget(self: *Atlas, slot: u16) void {
    var walk = self.entries.iterator();
    while (walk.next()) |entry| {
        // Safe while walking: a removal only marks the slot the walk has
        // just passed as deleted, and moves nothing.
        if (entry.key_ptr.face == slot) self.entries.removeByPtr(entry.key_ptr);
    }
}

/// Throw every glyph away and start again at the top left.
///
/// The pixels are cleared as well as the entries. A glyph packed later lands
/// on top of old ink, and its one pixel of padding is only padding if it is
/// empty - otherwise the sampler reaches into what was there before, and the
/// new letter grows the old one's edges.
pub fn clear(self: *Atlas) void {
    self.entries.clearRetainingCapacity();
    @memset(self.pixels, 0);
    self.pen_x = padding;
    self.pen_y = padding;
    self.shelf_height = 0;
    self.dirty = true;
}

/// Say the texture has been uploaded. See `dirty`.
pub inline fn markClean(self: *Atlas) void {
    self.dirty = false;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn systemFont(gpa: Allocator) !?[]u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/consola.ttf",
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
    for (candidates) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(32 << 20)) catch continue;
    }
    return null;
}

test "a glyph is rasterised once and found again after that" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const first = try atlas.glyph(&face, 0, face.glyphFor('H'), 16);
    try testing.expectEqual(1, atlas.count());
    try testing.expect(!first.isBlank());
    try testing.expect(first.advance > 0);

    // The second ask is the same entry and adds nothing - which is the whole
    // point of an atlas.
    const again = try atlas.glyph(&face, 0, face.glyphFor('H'), 16);
    try testing.expectEqual(1, atlas.count());
    try testing.expectEqual(first.u0, again.u0);
    try testing.expectEqual(first.v0, again.v0);
}

test "the same letter at two sizes is two pictures" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const small = try atlas.glyph(&face, 0, face.glyphFor('H'), 12);
    const large = try atlas.glyph(&face, 0, face.glyphFor('H'), 24);

    try testing.expectEqual(2, atlas.count());
    try testing.expect(large.height > small.height);
    // And they are in different places, so one cannot be drawn as the other.
    try testing.expect(small.u0 != large.u0 or small.v0 != large.v0);
}

test "a space takes an entry and no room" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const before = atlas.pen_x;
    const space = try atlas.glyph(&face, 0, face.glyphFor(' '), 16);

    // The advance is on it, so the pen still moves; there is nothing to draw,
    // so the shelf did not.
    try testing.expect(space.isBlank());
    try testing.expect(space.advance > 0);
    try testing.expectEqual(before, atlas.pen_x);
}

test "glyphs go onto shelves, and a new shelf starts below the last" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    // Narrow enough that a handful of letters fills a row.
    var atlas: Atlas = try .init(testing.allocator, 64, 256);
    defer atlas.deinit();

    var lowest: f32 = 0;
    for ("abcdefghijklmnop") |character| {
        const entry = try atlas.glyph(&face, 0, face.glyphFor(character), 16);
        lowest = @max(lowest, entry.v1);
    }

    try testing.expectEqual(16, atlas.count());
    // It wrapped onto at least a second shelf, which is what a narrow atlas
    // is for testing.
    try testing.expect(atlas.pen_y > padding);
    try testing.expect(lowest > 0);
}

test "an atlas too small to hold a glyph says so rather than overrunning" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 8, 8);
    defer atlas.deinit();

    // A 64-pixel letter into an eight-pixel atlas.
    try testing.expectError(error.AtlasFull, atlas.glyph(&face, 0, face.glyphFor('W'), 64));
}

test "adding a glyph marks the texture as needing an upload" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    try testing.expect(!atlas.dirty);
    _ = try atlas.glyph(&face, 0, face.glyphFor('A'), 16);
    try testing.expect(atlas.dirty);

    atlas.markClean();
    try testing.expect(!atlas.dirty);

    // A glyph already in it changes nothing, so a frame that draws only what
    // it drew last frame uploads nothing.
    _ = try atlas.glyph(&face, 0, face.glyphFor('A'), 16);
    try testing.expect(!atlas.dirty);
}

test "the pixels of a glyph actually reach the atlas" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const entry = try atlas.glyph(&face, 0, face.glyphFor('H'), 32);

    // Somewhere inside the letter there is ink. A packer that computed the
    // right rectangle and copied nothing would pass every test above this
    // one.
    var ink: usize = 0;
    const x0: u32 = @intFromFloat(entry.u0 * @as(f32, @floatFromInt(atlas.width)));
    const y0: u32 = @intFromFloat(entry.v0 * @as(f32, @floatFromInt(atlas.height)));
    for (0..entry.height) |row| {
        for (0..entry.width) |column| {
            if (atlas.pixels[(y0 + row) * atlas.width + x0 + column] > 128) ink += 1;
        }
    }
    try testing.expect(ink > 10);
}

test "the same glyph in two faces is two pictures" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    // One font in two slots is enough to see it: the slot is in the key, so
    // the second is rasterised again rather than taken for the first - which
    // is what stops glyph 43 of one font being drawn as glyph 43 of another.
    const first = try atlas.glyph(&face, 0, face.glyphFor('H'), 16);
    const second = try atlas.glyph(&face, 1, face.glyphFor('H'), 16);

    try testing.expectEqual(2, atlas.count());
    try testing.expect(first.u0 != second.u0 or first.v0 != second.v0);
}

test "forgetting a face drops its glyphs and keeps the other faces'" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    for ([_]u16{ 0, 1 }) |slot| {
        for ("ABC") |character| _ = try atlas.glyph(&face, slot, face.glyphFor(character), 16);
    }
    try testing.expectEqual(6, atlas.count());

    atlas.forget(1);
    try testing.expectEqual(3, atlas.count());

    // The first face's are still there, so asking adds nothing; the
    // forgotten face's are rasterised again when they are next asked for.
    _ = try atlas.glyph(&face, 0, face.glyphFor('A'), 16);
    try testing.expectEqual(3, atlas.count());
    _ = try atlas.glyph(&face, 1, face.glyphFor('A'), 16);
    try testing.expectEqual(4, atlas.count());
}

test "clearing an atlas starts it again, pixels and all" {
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    const face: font.Font = try .init(bytes);

    var atlas: Atlas = try .init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const before = try atlas.glyph(&face, 0, face.glyphFor('H'), 32);
    _ = try atlas.glyph(&face, 0, face.glyphFor('W'), 32);
    atlas.markClean();

    atlas.clear();
    try testing.expectEqual(0, atlas.count());
    try testing.expectEqual(0, atlas.shelf_height);
    // Blank, because old ink under the next glyph's padding would bleed into
    // it - and marked, so the blank texture is what gets uploaded.
    try testing.expect(std.mem.allEqual(u8, atlas.pixels, 0));
    try testing.expect(atlas.dirty);

    // The next glyph goes back to the top left, where the first one was.
    const after = try atlas.glyph(&face, 0, face.glyphFor('H'), 32);
    try testing.expectEqual(before.u0, after.u0);
    try testing.expectEqual(before.v0, after.v0);
}
