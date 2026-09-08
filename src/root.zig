// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion UI - a layout engine that draws nothing.
//!
//! Five pieces:
//!
//!   `Ui`        the frame: open, close, and the three passes that follow
//!   `layout`    what an element asks for - sizing, padding, direction
//!   `geometry`  rectangles, and the numbers that place one
//!   `color`     a colour, and the three ways people write one down
//!   `commands`  what a frame comes out as, and the seam a renderer sits on
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
//! for (try ui.end()) |command| draw(command);
//! ```
//!
//! **There is no renderer here, and there will not be.** A frame comes out as
//! a list of `commands.RenderCommand` and something else draws it - the RHI
//! backend, a WebGL one, a test that counts rectangles. That seam is what
//! makes the same layout run on a desktop, in a browser, and on a build
//! server with no GPU at all.
//!
//! This is a port of [Ply](https://github.com/TheRedDeveloper/ply-engine),
//! whose layout is in turn Clay's. What is here is the layout core; see the
//! README for what has and has not arrived yet.

const std = @import("std");

pub const color = @import("color.zig");
pub const commands = @import("commands.zig");
pub const geometry = @import("geometry.zig");
pub const input = @import("input.zig");
pub const layout = @import("layout.zig");
pub const text = @import("text.zig");

/// The frame: open, close, and the three passes that follow. See `Ui`.
pub const Ui = @import("Ui.zig");

pub const Color = color.Color;
pub const BoundingBox = geometry.BoundingBox;
pub const Dimensions = geometry.Dimensions;
pub const Padding = geometry.Padding;
pub const CornerRadius = geometry.CornerRadius;

pub const Declaration = layout.Declaration;
pub const Sizing = layout.Sizing;
pub const Direction = layout.Direction;
pub const Border = layout.Border;
pub const BorderWidth = layout.BorderWidth;
pub const BorderPosition = layout.BorderPosition;
pub const SlotFit = layout.SlotFit;
pub const Clip = layout.Clip;
pub const Scrollbar = layout.Scrollbar;

pub const AlignX = geometry.AlignX;
pub const AlignY = geometry.AlignY;

pub const Pointer = input.Pointer;
pub const PointerState = input.PointerState;

pub const TextStyle = text.TextStyle;
pub const Measurer = text.Measurer;
pub const WrapMode = text.WrapMode;

pub const RenderCommand = commands.RenderCommand;
pub const Config = commands.Config;

test {
    _ = color;
    _ = commands;
    _ = geometry;
    _ = input;
    _ = layout;
    _ = text;
    _ = Ui;
}
