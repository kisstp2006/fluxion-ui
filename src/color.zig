// SPDX-License-Identifier: BSL-1.0

//! A colour, and the three ways people write one down.
//!
//! Four floats from zero to one, which is what a GPU takes and what
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) hands to a clear
//! or a uniform without touching. Ply keeps the same four floats from zero to
//! *255*, and that is worth naming as a deliberate difference rather than a
//! typo: it is macroquad's convention showing through, and it means every
//! colour crossing into a shader has to be divided by something first. The
//! division happens once, here, in `hex`.
//!
//! ```zig
//! const bg: Color = .hex(0x262220);          // what the API is written in
//! const fg: Color = .rgba(1, 1, 1, 0.8);     // when the alpha is not 1
//! const accent: Color = .oklch(0.7, 0.14, 81);
//! ```
//!
//! `hex` is the one to reach for. A UI is written in hex because that is what
//! designers hand over, and `0x262220` is unambiguous in a way that
//! `.{ 0.149, 0.133, 0.125, 1 }` is not.

const std = @import("std");
const testing = std.testing;

/// Red, green, blue and alpha, each from zero to one.
///
/// `extern` because an array of these goes into a vertex buffer or a uniform
/// block with a `memcpy` and no repacking - the same reason every type in
/// [Fluxion Math](https://github.com/kisstp2006/fluxion-math) is.
pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

    /// `0xRRGGBB`, opaque. The spelling a UI is actually written in.
    pub inline fn hex(value: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
            .a = 1,
        };
    }

    /// `0xRRGGBBAA`. The alpha is last, as CSS writes it, and not first as
    /// Windows does - which is the mistake this doc comment exists to stop.
    pub inline fn hexa(value: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((value >> 24) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
            .a = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
        };
    }

    pub inline fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub inline fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Eight bits a channel, as a driver or an image file hands them over.
    pub inline fn bytes(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// Lightness, chroma and hue in degrees, from the Oklab colour space.
    ///
    /// Worth having in a UI library rather than being a curiosity. Two
    /// colours a designer picked to be "the same brightness" are the same
    /// lightness here and are not in HSL, so a theme built by varying `h`
    /// with `l` and `c` held still does not have one swatch that jumps out.
    /// Darkening a button on hover is `l - 0.05` and nothing else.
    ///
    /// Out-of-gamut values are clipped per channel, which is what every
    /// browser does and is wrong in the same way theirs is.
    pub fn oklch(l_in: f32, c_in: f32, h_degrees: f32) Color {
        const l = std.math.clamp(l_in, 0, 1);
        const c = @max(c_in, 0);
        const h = std.math.degreesToRadians(@mod(h_degrees, 360));

        const a = c * @cos(h);
        const b = c * @sin(h);

        const l_ = l + 0.39633778 * a + 0.21580376 * b;
        const m_ = l - 0.105561346 * a - 0.06385417 * b;
        const s_ = l - 0.08948418 * a - 1.2914855 * b;

        const l3 = l_ * l_ * l_;
        const m3 = m_ * m_ * m_;
        const s3 = s_ * s_ * s_;

        return .{
            .r = toSrgb(4.0767417 * l3 - 3.3077116 * m3 + 0.23096994 * s3),
            .g = toSrgb(-1.268438 * l3 + 2.6097574 * m3 - 0.34131938 * s3),
            .b = toSrgb(-0.0041960863 * l3 - 0.7034186 * m3 + 1.7076147 * s3),
            .a = 1,
        };
    }

    /// Linear light to sRGB. The curve is not a plain gamma, and using 2.2
    /// instead gets the dark end visibly wrong.
    fn toSrgb(linear: f32) f32 {
        const v = std.math.clamp(linear, 0, 1);
        const encoded = if (v <= 0.0031308)
            v * 12.92
        else
            1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        return std.math.clamp(encoded, 0, 1);
    }

    /// The same colour at a different opacity. What a disabled control is.
    pub inline fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    /// Whether anything would be drawn at all. A fully transparent fill is
    /// the usual way to say "lay this out but do not paint it", and the
    /// command generator skips it rather than sending the GPU a no-op.
    pub inline fn invisible(self: Color) bool {
        return self.a <= 0;
    }

    /// Straight-line interpolation, alpha included. Not perceptually even -
    /// `oklch` is where that lives - but it is what an animation between two
    /// known colours wants, and it is what every UI does.
    pub inline fn lerp(from: Color, to: Color, t: f32) Color {
        return .{
            .r = from.r + (to.r - from.r) * t,
            .g = from.g + (to.g - from.g) * t,
            .b = from.b + (to.b - from.b) * t,
            .a = from.a + (to.a - from.a) * t,
        };
    }

    /// The four floats, for a uniform or a vertex.
    pub inline fn array(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    pub fn format(self: Color, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{X:0>2}{X:0>2}{X:0>2}", .{
            @as(u8, @intFromFloat(@round(std.math.clamp(self.r, 0, 1) * 255))),
            @as(u8, @intFromFloat(@round(std.math.clamp(self.g, 0, 1) * 255))),
            @as(u8, @intFromFloat(@round(std.math.clamp(self.b, 0, 1) * 255))),
        });
        if (self.a < 1) try w.print("@{d:.2}", .{self.a});
    }
};

test "hex is the spelling a UI is written in" {
    const bg: Color = .hex(0x262220);
    try testing.expectApproxEqAbs(@as(f32, 0x26) / 255.0, bg.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x22) / 255.0, bg.g, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, bg.b, 1e-6);
    try testing.expectEqual(@as(f32, 1), bg.a);

    // And white is exactly one, not 0.996 - which is what dividing by 256
    // rather than 255 would give, and is the bug this checks for.
    try testing.expectEqual(Color.white, Color.hex(0xFFFFFF));
    try testing.expectEqual(Color.black, Color.hex(0x000000));
}

test "hexa puts the alpha last, as CSS does" {
    const half: Color = .hexa(0xFF000080);
    try testing.expectEqual(@as(f32, 1), half.r);
    try testing.expectEqual(@as(f32, 0), half.g);
    try testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, half.a, 1e-6);
}

test "oklch holds lightness still while the hue turns" {
    // The point of the space: three colours a designer would call equally
    // bright come out equally bright, which HSL does not manage.
    const a = Color.oklch(0.7, 0.14, 30);
    const b = Color.oklch(0.7, 0.14, 150);
    const c = Color.oklch(0.7, 0.14, 270);

    const luma = struct {
        fn of(col: Color) f32 {
            return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
        }
    }.of;

    // Within a few percent of each other, where HSL would be a factor of two
    // apart between yellow and blue.
    try testing.expectApproxEqAbs(luma(a), luma(b), 0.12);
    try testing.expectApproxEqAbs(luma(b), luma(c), 0.12);

    // Every channel stayed in gamut.
    for ([_]Color{ a, b, c }) |col| {
        for ([_]f32{ col.r, col.g, col.b }) |channel| {
            try testing.expect(channel >= 0 and channel <= 1);
        }
    }
}

test "oklch with no chroma is a grey, and lightness orders greys" {
    const dark = Color.oklch(0.2, 0, 0);
    const light = Color.oklch(0.8, 0, 0);

    try testing.expectApproxEqAbs(dark.r, dark.g, 1e-5);
    try testing.expectApproxEqAbs(dark.g, dark.b, 1e-5);
    try testing.expect(light.r > dark.r);
}

test "alpha, lerping and invisibility" {
    const red: Color = .hex(0xFF0000);
    try testing.expect(!red.invisible());
    try testing.expect(red.withAlpha(0).invisible());
    try testing.expect(Color.transparent.invisible());

    const halfway = Color.lerp(Color.black, Color.white, 0.5);
    try testing.expectApproxEqAbs(0.5, halfway.r, 1e-6);
    try testing.expectEqual(@as(f32, 1), halfway.a);
}

test "a colour prints as the hex it was written as" {
    var text: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);

    try w.print("{f}", .{Color.hex(0x262220)});
    try testing.expectEqualStrings("#262220", w.buffered());

    w = .fixed(&text);
    try w.print("{f}", .{Color.hex(0xFF0000).withAlpha(0.5)});
    try testing.expectEqualStrings("#FF0000@0.50", w.buffered());
}
