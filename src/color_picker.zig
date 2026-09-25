// SPDX-License-Identifier: BSD-2-Clause

//! A colour picker: a square of saturation and value beside a bar of hues,
//! or a wheel of hues and saturations beside a bar of values, a bar of
//! alpha, the colour it opened with beside the new one, and fields for its
//! hex, its channels and its hue, saturation and value.
//!
//! ```zig
//! var picking: ColorPicker.State = .init(swatch_color);
//! // each frame, inside whatever floats it where the program wants it:
//! if (ColorPicker.picker(&ui, &picking, .{ .id = "tint-picker" })) swatch_color = picking.color();
//! ```
//!
//! The picker holds its colour as hue, saturation and value, so a colour
//! made grey keeps its hue, and a hue dragged while the colour is black is
//! not lost. It reads the pointer from where its parts were laid out last
//! frame, as everything in this library does, and takes a press on any of
//! them - the square, the wheel, a bar - and follows the drag until the
//! button comes up, wherever the pointer goes meanwhile.
//!
//! Every id it declares is made from `Options.id`: `tint-picker-square`,
//! `tint-picker-hex`, and so on. Two pickers at once need two ids.

const std = @import("std");
const testing = std.testing;

const Ui = @import("Ui.zig");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const Color = @import("color.zig").Color;

pub const Mode = enum { square, wheel };

/// What a press on the picker has hold of, until the button comes up.
pub const Part = enum { none, square, hue, wheel, value, alpha };

/// The picker's colours: what it is drawn in, not what it picks.
pub const Style = struct {
    font_size: u16 = 13,
    text: Color = .hex(0xDADADA),
    dim: Color = .hex(0x9A9A9A),
    field: Color = .hex(0x1C1C1C),
    border: Color = .hex(0x505050),
    accent: Color = .hex(0x4C9AFF),
    checker: Color = .hex(0x6A6A6A),
};

pub const Options = struct {
    /// What every id the picker declares is made from.
    id: []const u8 = "color-picker",
    /// The side of the square, or of the wheel.
    size: f32 = 180,
    /// Whether it picks an alpha too; without, the alpha stays as it was.
    alpha: bool = true,
    style: Style = .{},
};

pub const State = struct {
    /// From nought to one round the colours: red, yellow, green, cyan,
    /// blue, magenta, and red again.
    hue: f32 = 0,
    saturation: f32 = 0,
    value: f32 = 1,
    alpha: f32 = 1,
    mode: Mode = .square,
    held: Part = .none,
    /// What it opened with: shown beside the new colour, and a press on it
    /// goes back to it.
    before: Color = .white,

    pub fn init(c: Color) State {
        var made: State = .{ .before = c };
        made.set(c);
        return made;
    }

    /// Hold `c`, keeping the hue when it has none - a grey - and the
    /// saturation when it is black.
    pub fn set(self: *State, c: Color) void {
        const hsv = c.toHsv();
        if (hsv[1] > 0 and hsv[2] > 0) self.hue = hsv[0];
        if (hsv[2] > 0) self.saturation = hsv[1];
        self.value = hsv[2];
        self.alpha = std.math.clamp(c.a, 0, 1);
    }

    pub fn color(self: State) Color {
        return Color.hsv(self.hue, self.saturation, self.value, self.alpha);
    }
};

/// Declare the picker here, in the element the caller has open, and take
/// this frame's pointer and fields to its colour. Whether the colour
/// changed.
pub fn picker(ui: *Ui, state: *State, options: Options) bool {
    var names: Names = .{ .base = options.id };
    var changed = follow(ui, state, options, &names);
    const style = options.style;

    ui.open(.{ .direction = .top_to_bottom, .gap = 8 });
    defer ui.close();

    // Before and after, the hex, and the two views.
    {
        ui.open(.{ .direction = .left_to_right, .gap = 6, .align_y = .center });
        defer ui.close();
        ui.open(.{ .id = names.of("swatches"), .width = .fixed(48), .height = .fixed(22), .direction = .left_to_right, .border = .all(style.border, 1) });
        swatch(ui, names.of("before"), state.before, style);
        swatch(ui, names.of("after"), state.color(), style);
        ui.close();
        if (ui.isElementReleased(names.of("before"))) {
            state.set(state.before);
            changed = true;
        }
        changed = hexField(ui, state, style, names.of("hex")) or changed;
        if (button(ui, names.of("square-mode"), "Square", state.mode == .square, style)) state.mode = .square;
        if (button(ui, names.of("wheel-mode"), "Wheel", state.mode == .wheel, style)) state.mode = .wheel;
    }

    {
        ui.open(.{ .direction = .left_to_right, .gap = 8 });
        defer ui.close();
        switch (state.mode) {
            .square => {
                square(ui, state, options, names.of("square"));
                hueBar(ui, state, options, names.of("hue"));
            },
            .wheel => {
                wheel(ui, state, options, names.of("wheel"));
                valueBar(ui, state, options, names.of("value"));
            },
        }
        if (options.alpha) alphaBar(ui, state, options, names.of("alpha"));
    }

    // The channels, then hue, saturation and value.
    const rgba = state.color();
    const channels = [_]struct { []const u8, f32, f32 }{
        .{ "R", rgba.r, 255 }, .{ "G", rgba.g, 255 }, .{ "B", rgba.b, 255 }, .{ "A", rgba.a, 255 },
    };
    {
        ui.open(.{ .direction = .left_to_right, .gap = 4, .align_y = .center });
        defer ui.close();
        for (channels, 0..) |channel, i| {
            if (i == 3 and !options.alpha) break;
            if (numberField(ui, style, &names, channel[0], channel[1] * channel[2], channel[2])) |typed| {
                var c = state.color();
                const v = typed / channel[2];
                switch (i) {
                    0 => c.r = v,
                    1 => c.g = v,
                    2 => c.b = v,
                    else => c.a = v,
                }
                state.set(c);
                changed = true;
            }
        }
    }
    {
        ui.open(.{ .direction = .left_to_right, .gap = 4, .align_y = .center });
        defer ui.close();
        if (numberField(ui, style, &names, "H", state.hue * 360, 360)) |typed| {
            state.hue = @mod(typed / 360, 1);
            changed = true;
        }
        if (numberField(ui, style, &names, "S", state.saturation * 100, 100)) |typed| {
            state.saturation = typed / 100;
            changed = true;
        }
        if (numberField(ui, style, &names, "V", state.value * 100, 100)) |typed| {
            state.value = typed / 100;
            changed = true;
        }
    }
    return changed;
}

/// The ids of one picker's parts, made from its own.
const Names = struct {
    base: []const u8,
    buffer: [8][96]u8 = undefined,
    next: usize = 0,

    /// `base-part`. Each call has a buffer of its own for this frame, round
    /// eight of them: an id is hashed as it is declared, so none is kept.
    fn of(self: *Names, part: []const u8) []const u8 {
        const into = &self.buffer[self.next % self.buffer.len];
        self.next += 1;
        return std.fmt.bufPrint(into, "{s}-{s}", .{ self.base, part }) catch self.base;
    }
};

/// Take the pointer to whatever part it pressed, from where the parts
/// were laid out last frame. Whether the colour changed.
fn follow(ui: *Ui, state: *State, options: Options, names: *Names) bool {
    const p = ui.pointer;
    if (p.justPressed()) {
        state.held = .none;
        const parts = [_]struct { Part, []const u8 }{
            .{ .square, "square" }, .{ .hue, "hue" }, .{ .wheel, "wheel" }, .{ .value, "value" }, .{ .alpha, "alpha" },
        };
        for (parts) |part| {
            const box = ui.boxOf(names.of(part[1])) orelse continue;
            if (!contains(box, p.position)) continue;
            if (part[0] == .wheel and !onWheel(box, p.position)) continue;
            state.held = part[0];
        }
    }
    if (!p.isDown()) {
        state.held = .none;
        return false;
    }
    const name = switch (state.held) {
        .none => return false,
        .square => "square",
        .hue => "hue",
        .wheel => "wheel",
        .value => "value",
        .alpha => "alpha",
    };
    const box = ui.boxOf(names.of(name)) orelse return false;
    const fx = std.math.clamp((p.position.x - box.x) / @max(box.width, 1), 0, 1);
    const fy = std.math.clamp((p.position.y - box.y) / @max(box.height, 1), 0, 1);
    switch (state.held) {
        .square => {
            state.saturation = fx;
            state.value = 1 - fy;
        },
        .hue => state.hue = @min(fy, 0.9999),
        .value => state.value = 1 - fy,
        .alpha => state.alpha = 1 - fy,
        .wheel => {
            const radius = @min(box.width, box.height) / 2;
            const dx = p.position.x - (box.x + box.width / 2);
            const dy = p.position.y - (box.y + box.height / 2);
            state.hue = @mod(std.math.atan2(dy, dx) / (2 * std.math.pi), 1);
            state.saturation = std.math.clamp(@sqrt(dx * dx + dy * dy) / @max(radius, 1), 0, 1);
        },
        .none => {},
    }
    _ = options;
    return true;
}

fn contains(box: geometry.BoundingBox, at: geometry.Vec2) bool {
    return at.x >= box.x and at.x < box.x + box.width and at.y >= box.y and at.y < box.y + box.height;
}

fn onWheel(box: geometry.BoundingBox, at: geometry.Vec2) bool {
    const radius = @min(box.width, box.height) / 2;
    const dx = at.x - (box.x + box.width / 2);
    const dy = at.y - (box.y + box.height / 2);
    return dx * dx + dy * dy <= radius * radius;
}

/// Half of the before-and-after plate, over a checker so its alpha shows.
fn swatch(ui: *Ui, id: []const u8, c: Color, style: Style) void {
    ui.open(.{ .id = id, .width = .grow, .height = .grow, .background_color = style.checker });
    ui.empty(.{ .width = .grow, .height = .grow, .background_color = c });
    ui.close();
}

/// A small button, lit while `on`. Whether it was pressed.
fn button(ui: *Ui, id: []const u8, label: []const u8, on: bool, style: Style) bool {
    const pressed = ui.isElementReleased(id);
    ui.open(.{
        .id = id,
        .padding = .xy(6, 2),
        .corner_radius = .all(3),
        .background_color = if (on) style.accent.withAlpha(0.35) else if (ui.isPointerOver(id)) style.border else .transparent,
        .border = .all(style.border, 1),
    });
    ui.text(label, .{ .font_size = style.font_size - 1, .color = if (on) style.text else style.dim });
    ui.close();
    return pressed;
}

/// The square: saturation across, value down, over the hue.
fn square(ui: *Ui, state: *const State, options: Options, id: []const u8) void {
    const side = options.size;
    const pure = Color.hsv(state.hue, 1, 1, 1);
    ui.open(.{
        .id = id,
        .width = .fixed(side),
        .height = .fixed(side),
        .background_color = .white,
        .gradient = .{ .to = pure },
    });
    defer ui.close();
    ui.empty(.{
        .width = .fixed(side),
        .height = .fixed(side),
        .background_color = .rgba(0, 0, 0, 0),
        .gradient = .{ .to = .black, .toward = .down },
        .floating = .{ .attach = .parent, .z_index = 1 },
    });
    marker(ui, state.saturation * side, (1 - state.value) * side, state.color());
}

/// A ring where the colour is on the square or the wheel.
fn marker(ui: *Ui, x: f32, y: f32, c: Color) void {
    const r: f32 = 6;
    ui.empty(.{
        .width = .fixed(2 * r),
        .height = .fixed(2 * r),
        .corner_radius = .all(r),
        .background_color = c.withAlpha(1),
        .border = .all(if (c.r * 0.3 + c.g * 0.59 + c.b * 0.11 > 0.5) Color.black else Color.white, 2),
        .floating = .{ .attach = .parent, .offset = .{ .x = x - r, .y = y - r }, .z_index = 2 },
    });
}

/// A line across a bar where its value is.
fn notch(ui: *Ui, width: f32, y: f32) void {
    ui.empty(.{
        .width = .fixed(width + 4),
        .height = .fixed(3),
        .background_color = .white,
        .border = .all(.black, 1),
        .floating = .{ .attach = .parent, .offset = .{ .x = -2, .y = y - 1.5 }, .z_index = 2 },
    });
}

const bar_width: f32 = 16;

/// Every hue down the bar, red at both ends.
fn hueBar(ui: *Ui, state: *const State, options: Options, id: []const u8) void {
    const height = options.size;
    ui.open(.{ .id = id, .width = .fixed(bar_width), .height = .fixed(height), .direction = .top_to_bottom });
    defer ui.close();
    const stops = [_]u24{ 0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF, 0xFF0000 };
    for (stops[0 .. stops.len - 1], stops[1..]) |from, to| {
        ui.empty(.{ .width = .grow, .height = .grow, .background_color = .hex(from), .gradient = .{ .to = .hex(to), .toward = .down } });
    }
    notch(ui, bar_width, state.hue * height);
}

/// The value down the bar, from the brightest of this hue and saturation to
/// black.
fn valueBar(ui: *Ui, state: *const State, options: Options, id: []const u8) void {
    const height = options.size;
    ui.open(.{
        .id = id,
        .width = .fixed(bar_width),
        .height = .fixed(height),
        .background_color = Color.hsv(state.hue, state.saturation, 1, 1),
        .gradient = .{ .to = .black, .toward = .down },
    });
    defer ui.close();
    notch(ui, bar_width, (1 - state.value) * height);
}

/// The alpha down the bar over a checker, opaque at the top.
fn alphaBar(ui: *Ui, state: *const State, options: Options, id: []const u8) void {
    const height = options.size;
    ui.open(.{ .id = id, .width = .fixed(bar_width), .height = .fixed(height), .direction = .top_to_bottom, .background_color = .white });
    defer ui.close();
    const cell = bar_width / 2;
    const rows: usize = @intFromFloat(@ceil(height / cell));
    for (0..rows) |row| {
        ui.empty(.{
            .width = .fixed(cell),
            .height = .fixed(@min(cell, height - @as(f32, @floatFromInt(row)) * cell)),
            .background_color = options.style.checker,
            .floating = .{ .attach = .parent, .offset = .{ .x = if (row % 2 == 0) 0 else cell, .y = @as(f32, @floatFromInt(row)) * cell } },
        });
    }
    const c = state.color();
    ui.empty(.{
        .width = .fixed(bar_width),
        .height = .fixed(height),
        .background_color = c.withAlpha(1),
        .gradient = .{ .to = c.withAlpha(0), .toward = .down },
        .floating = .{ .attach = .parent, .z_index = 1 },
    });
    notch(ui, bar_width, (1 - state.alpha) * height);
}

/// The wheel: the hues round it, grey in the middle, darkened as the value
/// says. Drawn as thin bars out from the middle, each fading from white to
/// its hue, turned round the middle.
fn wheel(ui: *Ui, state: *const State, options: Options, id: []const u8) void {
    const side = options.size;
    const radius = side / 2;
    ui.open(.{ .id = id, .width = .fixed(side), .height = .fixed(side) });
    defer ui.close();
    const spokes = 120;
    const thickness = 2 * std.math.pi * radius / spokes * 1.6;
    for (0..spokes) |i| {
        const turn = @as(f32, @floatFromInt(i)) / spokes;
        ui.empty(.{
            .width = .fixed(radius),
            .height = .fixed(thickness),
            .background_color = .white,
            .gradient = .{ .to = Color.hsv(turn, 1, 1, 1) },
            .rotate = .{ .radians = turn * 2 * std.math.pi, .pivot = .{ .x = 0, .y = 0.5 } },
            .floating = .{ .attach = .parent, .offset = .{ .x = radius, .y = radius - thickness / 2 } },
        });
    }
    // The value, as black over the whole wheel.
    ui.empty(.{
        .width = .fixed(side),
        .height = .fixed(side),
        .corner_radius = .all(radius),
        .background_color = .rgba(0, 0, 0, 1 - state.value),
        .floating = .{ .attach = .parent, .z_index = 1 },
    });
    // A clean edge over the spokes' square ends.
    ui.empty(.{
        .width = .fixed(side + 4),
        .height = .fixed(side + 4),
        .corner_radius = .all(radius + 2),
        .border = .all(options.style.field, 3),
        .floating = .{ .attach = .parent, .offset = .{ .x = -2, .y = -2 }, .z_index = 1 },
    });
    const angle = state.hue * 2 * std.math.pi;
    marker(ui, radius + @cos(angle) * state.saturation * radius, radius + @sin(angle) * state.saturation * radius, state.color());
}

/// The colour as `#RRGGBB`, or `#RRGGBBAA` when it is not opaque.
pub fn hexOf(buffer: []u8, c: Color) []const u8 {
    const r = byte(c.r);
    const g = byte(c.g);
    const b = byte(c.b);
    const a = byte(c.a);
    if (a == 255) return std.fmt.bufPrint(buffer, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch "";
    return std.fmt.bufPrint(buffer, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b, a }) catch "";
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA`, the `#` or not.
pub fn parseHex(text: []const u8) ?Color {
    const digits = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, text, " "), "#"), " ");
    const n = std.fmt.parseInt(u32, digits, 16) catch return null;
    return switch (digits.len) {
        3 => .bytes(@intCast(((n >> 8) & 0xF) * 17), @intCast(((n >> 4) & 0xF) * 17), @intCast((n & 0xF) * 17), 255),
        6 => .bytes(@intCast((n >> 16) & 0xFF), @intCast((n >> 8) & 0xFF), @intCast(n & 0xFF), 255),
        8 => .bytes(@intCast((n >> 24) & 0xFF), @intCast((n >> 16) & 0xFF), @intCast((n >> 8) & 0xFF), @intCast(n & 0xFF)),
        else => null,
    };
}

/// The hex, written by the picker while it is not being typed in, and taken
/// as soon as what is typed is a colour. Whether it changed the colour.
fn hexField(ui: *Ui, state: *State, style: Style, id: []const u8) bool {
    field(ui, style, id, 84);
    if (!ui.isFocused(id)) {
        var buffer: [16]u8 = undefined;
        ui.setTextValue(id, hexOf(&buffer, state.color()));
        return false;
    }
    if (!ui.textChanged(id) and !ui.textSubmitted(id)) return false;
    const c = parseHex(ui.textValueOf(id) orelse "") orelse return false;
    state.set(c);
    return true;
}

/// A letter and a whole number from nought to `most`, written by the picker
/// while it is not being typed in. The number typed, once it is one.
fn numberField(ui: *Ui, style: Style, names: *Names, letter: []const u8, shown: f32, most: f32) ?f32 {
    const id = names.of(letter);
    ui.text(letter, .{ .font_size = style.font_size - 1, .color = style.dim });
    field(ui, style, id, 38);
    if (!ui.isFocused(id)) {
        var buffer: [16]u8 = undefined;
        ui.setTextValue(id, std.fmt.bufPrint(&buffer, "{d}", .{@round(shown)}) catch "");
        return null;
    }
    if (!ui.textChanged(id) and !ui.textSubmitted(id)) return null;
    const typed = std.fmt.parseFloat(f32, std.mem.trim(u8, ui.textValueOf(id) orelse "", " ")) catch return null;
    return std.math.clamp(typed, 0, most);
}

fn field(ui: *Ui, style: Style, id: []const u8, width: f32) void {
    ui.textInput(.{
        .id = id,
        .width = .fixed(width),
        .height = .fixed(@as(f32, @floatFromInt(style.font_size)) + 8),
        .padding = .xy(4, 2),
        .corner_radius = .all(3),
        .background_color = style.field,
        .border = .all(if (ui.isFocused(id)) style.accent else style.border, 1),
    }, .{
        .font_size = style.font_size,
        .text_color = style.text,
        .cursor_color = style.text,
    });
}

// ---------------------------------------------------------------------------
// Tests

test "a colour is held as hue, saturation and value, and a grey keeps its hue" {
    var state: State = .init(.hex(0x3366CC));
    try testing.expectApproxEqAbs(@as(f32, 220.0 / 360.0), state.hue, 0.002);
    try testing.expectApproxEqAbs(@as(f32, 0.8), state.value, 0.002);
    const back = state.color();
    try testing.expectApproxEqAbs(@as(f32, 0.2), back.r, 0.002);
    try testing.expectApproxEqAbs(@as(f32, 0.8), back.b, 0.002);

    // Made grey, and made red again by its saturation alone: the hue stayed.
    state.set(.hex(0x808080));
    try testing.expectApproxEqAbs(@as(f32, 220.0 / 360.0), state.hue, 0.002);
    state.saturation = 1;
    try testing.expect(state.color().b > state.color().r);
}

test "a hex is read as three, six or eight digits and written as six, or eight with an alpha" {
    try testing.expectApproxEqAbs(@as(f32, 1), parseHex("#F80").?.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0x88.0 / 255.0), parseHex("F80").?.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0x80.0 / 255.0), parseHex("#11223380").?.a, 0.001);
    try testing.expect(parseHex("#12") == null);
    try testing.expect(parseHex("nope") == null);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("#3366CC", hexOf(&buffer, .hex(0x3366CC)));
    try testing.expectEqualStrings("#3366CC80", hexOf(&buffer, Color.hex(0x3366CC).withAlpha(0x80.0 / 255.0)));
}

test "a press on the square, a bar or the wheel takes the colour where it is, and a drag follows it" {
    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var state: State = .init(.hex(0xFF0000));
    const frame = struct {
        fn run(u: *Ui, s: *State) !bool {
            u.begin(.init(600, 400));
            u.open(.{ .width = .grow, .height = .grow });
            const changed = picker(u, s, .{ .id = "p", .size = 100 });
            u.close();
            _ = try u.end();
            return changed;
        }
    }.run;
    _ = try frame(&ui, &state);

    // The middle of the square: half saturated, half bright.
    const box = ui.boxOf("p-square").?;
    ui.setPointer(box.x + 50, box.y + 50, true);
    try testing.expect(try frame(&ui, &state));
    try testing.expectEqual(Part.square, state.held);
    try testing.expectApproxEqAbs(@as(f32, 0.5), state.saturation, 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.5), state.value, 0.02);
    // Dragged off the square to the right and up: full saturation, full value.
    ui.setPointer(box.x + 400, box.y - 50, true);
    _ = try frame(&ui, &state);
    try testing.expectEqual(@as(f32, 1), state.saturation);
    try testing.expectEqual(@as(f32, 1), state.value);
    ui.setPointer(box.x + 400, box.y - 50, false);
    _ = try frame(&ui, &state);
    try testing.expectEqual(Part.none, state.held);

    // A third of the way down the hues: green.
    const hues = ui.boxOf("p-hue").?;
    ui.setPointer(hues.x + 8, hues.y + hues.height / 3, true);
    _ = try frame(&ui, &state);
    try testing.expect(state.color().g > 0.9 and state.color().r < 0.1);
    ui.setPointer(hues.x + 8, hues.y + hues.height / 3, false);
    _ = try frame(&ui, &state);

    // The wheel, to the right of its middle at its edge: red, all of it.
    state.mode = .wheel;
    _ = try frame(&ui, &state);
    _ = try frame(&ui, &state);
    const round = ui.boxOf("p-wheel").?;
    ui.setPointer(round.x + round.width - 2, round.y + round.height / 2, true);
    _ = try frame(&ui, &state);
    try testing.expectEqual(Part.wheel, state.held);
    try testing.expect(state.hue < 0.02 or state.hue > 0.98);
    try testing.expect(state.saturation > 0.9);
}
