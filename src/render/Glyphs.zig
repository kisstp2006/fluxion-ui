// SPDX-License-Identifier: BSD-2-Clause

//! Glyphs drawn once and kept, for the CPU renderer.
//!
//! The GPU renderer keeps its glyphs in one texture, because that is what a
//! GPU can sample. A CPU has no such constraint, so each glyph here is its
//! own small bitmap in a map - and that buys the one thing the atlas cannot
//! give cheaply: **a glyph drawn at a quarter of a pixel**.
//!
//! A pen that has moved 7.25 pixels does not land on a pixel. The GPU puts
//! the glyph's quad there anyway and lets the texture filter smear it across
//! two columns, which is right on average and slightly soft everywhere. Here
//! the outline itself is moved by the quarter before it is rasterised, so the
//! coverage is the shape at that position rather than a blur of it at
//! another one. Four phases a pixel is where the difference stops being
//! visible; each phase is its own entry.
//!
//! Colour glyphs - emoji - come out premultiplied, the way the target is.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const font = @import("fluxion_font");

const Glyphs = @This();

/// How many positions within one pixel a glyph is drawn at.
pub const phases = 4;

pub const Key = struct {
    /// The renderer's slot for the face, so `forget` can find its glyphs.
    face: u16,
    glyph: u16,
    /// Pixels per em, whole - see `glyph`.
    size: u16,
    /// Quarters of a pixel to the right. Always zero for a colour glyph,
    /// which is a picture and is not redrawn for a nudge.
    phase: u8,
};

pub const Entry = struct {
    /// Coverage, a byte a pixel, for an ordinary glyph.
    coverage: []const u8 = &.{},
    /// Premultiplied pixels, alpha in the top byte, for a colour one.
    pixels: []const u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// How far right of the pen the bitmap starts.
    left: i32 = 0,
    /// How far above the baseline its top row is.
    top: i32 = 0,
    /// How far the pen moves afterwards, in pixels.
    advance: f32 = 0,
    colored: bool = false,

    /// A space, or anything else that moves the pen and draws nothing.
    pub fn isBlank(self: Entry) bool {
        return self.width == 0 or self.height == 0;
    }
};

gpa: Allocator,
entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
/// How many bytes the bitmaps take, all told.
bytes: usize = 0,
/// When to start again. A program that draws text at every size it ever
/// animates through would otherwise keep every one of them; emptied, the map
/// fills again with what is actually on the screen.
budget: usize = 16 << 20,
/// How colour glyphs are drawn. See `font.ColorOptions`.
color: font.ColorOptions = .{},

pub fn init(gpa: Allocator) Glyphs {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Glyphs) void {
    self.clear();
    self.entries.deinit(self.gpa);
    self.* = undefined;
}

/// Forget every glyph.
pub fn clear(self: *Glyphs) void {
    var it = self.entries.valueIterator();
    while (it.next()) |entry| self.free(entry.*);
    self.entries.clearRetainingCapacity();
    self.bytes = 0;
}

/// Forget the glyphs of one face, so they are drawn again from whatever is
/// in that slot now.
pub fn forget(self: *Glyphs, slot: u16) void {
    var doomed: std.ArrayList(Key) = .empty;
    defer doomed.deinit(self.gpa);

    var it = self.entries.iterator();
    while (it.next()) |found| {
        if (found.key_ptr.face != slot) continue;
        // Out of memory here only means the glyphs stay a little longer:
        // the whole map is emptied instead.
        doomed.append(self.gpa, found.key_ptr.*) catch return self.clear();
    }
    for (doomed.items) |key| {
        if (self.entries.fetchRemove(key)) |gone| {
            self.bytes -= sizeOf(gone.value);
            self.free(gone.value);
        }
    }
}

/// The glyph `index` of `face` at `size` pixels per em, nudged right by
/// `phase` quarters of a pixel - drawn now, or the one drawn before.
///
/// **The entry is good until the next call**, which may empty the map to
/// stay inside the budget. A renderer draws each glyph as soon as it has it,
/// which is all this asks.
pub fn glyph(self: *Glyphs, face: *const font.Font, slot: u16, index: u16, size: u16, phase: u8) font.Font.Error!Entry {
    const colored = face.hasColor(index);
    const key: Key = .{
        .face = slot,
        .glyph = index,
        .size = size,
        .phase = if (colored) 0 else phase % phases,
    };
    if (self.entries.get(key)) |found| return found;

    if (self.bytes > self.budget) self.clear();
    try self.entries.ensureUnusedCapacity(self.gpa, 1);

    const entry = (if (colored) try self.drawColored(face, index, size) else null) orelse
        try self.drawShape(face, index, size, key.phase);
    self.entries.putAssumeCapacity(key, entry);
    self.bytes += sizeOf(entry);
    return entry;
}

/// The outline, moved by the phase and rasterised.
fn drawShape(self: *Glyphs, face: *const font.Font, index: u16, size: u16, phase: u8) font.Font.Error!Entry {
    const em: f32 = @floatFromInt(size);
    const scale = face.scaleFor(em);
    const advance = try face.at(em).advance(index);

    var shape: font.Outline = .empty;
    defer shape.deinit(self.gpa);
    try face.outlineOf(self.gpa, index, &shape);
    if (shape.isEmpty() or scale == 0) return .{ .advance = advance };

    // In font units, before the placement is worked out, so the bitmap is
    // sized for the shape where it actually is.
    if (phase != 0) {
        const nudge = @as(f32, @floatFromInt(phase)) / phases / scale;
        shape.transform(1, 1, nudge, 0);
    }

    const placement: font.Placement = .init(shape.bounds(), scale);
    placement.apply(&shape);
    const bitmap = try font.raster.rasterize(self.gpa, shape, placement.width, placement.height);

    return .{
        .coverage = bitmap.pixels,
        .width = bitmap.width,
        .height = bitmap.height,
        .left = placement.left,
        .top = placement.top,
        .advance = advance,
    };
}

/// A colour glyph in its own colours, premultiplied. Null when its colour
/// form will not draw - a picture the decoder refuses - which leaves the
/// glyph its shape.
fn drawColored(self: *Glyphs, face: *const font.Font, index: u16, size: u16) Allocator.Error!?Entry {
    var drawn = face.renderColor(self.gpa, index, @floatFromInt(size), self.color) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    } orelse return null;
    defer drawn.deinit(self.gpa);

    const count = @as(usize, drawn.width) * drawn.height;
    const pixels = try self.gpa.alloc(u32, count);
    for (pixels, 0..) |*out, i| {
        const px = drawn.pixels[i * 4 ..][0..4];
        out.* = premultiply(px[0], px[1], px[2], px[3]);
    }

    return .{
        .pixels = pixels,
        .width = drawn.width,
        .height = drawn.height,
        .left = drawn.left,
        .top = drawn.top,
        .advance = drawn.advance,
        .colored = true,
    };
}

/// Straight RGBA bytes to one premultiplied pixel, alpha in the top byte.
pub fn premultiply(r: u8, g: u8, b: u8, a: u8) u32 {
    const alpha: u32 = a;
    const pr = (@as(u32, r) * alpha + 127) / 255;
    const pg = (@as(u32, g) * alpha + 127) / 255;
    const pb = (@as(u32, b) * alpha + 127) / 255;
    return alpha << 24 | pr << 16 | pg << 8 | pb;
}

fn sizeOf(entry: Entry) usize {
    return entry.coverage.len + entry.pixels.len * 4;
}

fn free(self: *Glyphs, entry: Entry) void {
    if (entry.coverage.len > 0) self.gpa.free(entry.coverage);
    if (entry.pixels.len > 0) self.gpa.free(entry.pixels);
}

test "premultiplying keeps every channel under its alpha" {
    try testing.expectEqual(@as(u32, 0x80804020), premultiply(255, 128, 64, 128));
    try testing.expectEqual(@as(u32, 0), premultiply(255, 255, 255, 0));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), premultiply(255, 255, 255, 255));
}
