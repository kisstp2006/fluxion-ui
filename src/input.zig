// SPDX-License-Identifier: BSD-2-Clause

//! Where the pointer is and what it is doing.
//!
//! One pointer, and that is deliberate: a mouse, a finger, a pen and a
//! trackpad all arrive here as the same two facts - a position and whether it
//! is down - and an interface that treats them differently is usually one
//! that has got something wrong. Ply makes the same choice.
//!
//! ```zig
//! ui.setPointer(mouse_x, mouse_y, mouse_down);   // before `begin`
//!
//! ui.open(.{ .id = "save", ... });
//! defer ui.close();
//! if (ui.hovered()) { ... }
//! if (ui.justReleased()) { save(); }
//! ```
//!
//! **The answers are one frame old**, and they have to be. `hovered` is asked
//! while the tree is being declared, and where an element ends up is not known
//! until the tree is finished - so it answers from where the element was last
//! frame. Every immediate-mode interface works this way, and it is invisible
//! at sixty frames a second except in the one case worth knowing about: an
//! element that has just appeared, or has just moved a long way, is not
//! hovered until the frame after.

const std = @import("std");
const testing = std.testing;

const geometry = @import("geometry.zig");

const Vec2 = geometry.Vec2;

/// What the pointer button is doing. Ply's `PointerState`, under Ply's names.
///
/// Four states rather than a boolean, because "went down this frame" and "is
/// down" are different questions and a button needs both: the first fires
/// once, the second draws the pressed look for as long as it is held.
pub const PointerState = enum {
    /// Not down, and was not released this frame either.
    idle,
    /// Went down this frame.
    pressed_this_frame,
    /// Down, and was already down last frame.
    pressed,
    /// Came up this frame.
    released_this_frame,

    /// Whether the button is down at all.
    pub inline fn isDown(self: PointerState) bool {
        return self == .pressed or self == .pressed_this_frame;
    }

    /// Whether it is up at all.
    pub inline fn isUp(self: PointerState) bool {
        return self == .idle or self == .released_this_frame;
    }

    /// The state one frame later, given whether the button is still down.
    ///
    /// The whole of the transition table, in one place. `pressed_this_frame`
    /// becomes `pressed` whether or not anybody asked, which is what makes
    /// "just pressed" fire exactly once.
    pub fn advance(self: PointerState, down: bool) PointerState {
        if (down) {
            return switch (self) {
                .pressed, .pressed_this_frame => .pressed,
                .idle, .released_this_frame => .pressed_this_frame,
            };
        }
        return switch (self) {
            .pressed, .pressed_this_frame => .released_this_frame,
            .idle, .released_this_frame => .idle,
        };
    }
};

/// Where the pointer is, and what its button is doing.
pub const Pointer = struct {
    position: Vec2 = .{ .x = 0, .y = 0 },
    state: PointerState = .idle,

    pub inline fn isDown(self: Pointer) bool {
        return self.state.isDown();
    }

    pub inline fn isUp(self: Pointer) bool {
        return self.state.isUp();
    }

    pub inline fn justPressed(self: Pointer) bool {
        return self.state == .pressed_this_frame;
    }

    pub inline fn justReleased(self: Pointer) bool {
        return self.state == .released_this_frame;
    }
};

/// Where the focus should go: what a key or a pad button *meant*, which is
/// all this library is ever told about either. See `Ui.navigate`.
///
/// The same arrangement as `text_input.Action`, and for the same reason. A
/// layout library has no business knowing that Tab is Tab on this keyboard,
/// that a pad's shoulder button means "next page" in this game, or that the
/// program has a key-binding screen - so the program decides what a key is
/// for, and this decides what that means for the focus.
pub const Navigation = enum {
    /// Tab: the next element in the Tab order, coming round at the end.
    next,
    /// Shift+Tab: the one before, coming round at the start.
    previous,
};

test "the transition table fires just-pressed exactly once" {
    var state: PointerState = .idle;

    state = state.advance(true);
    try testing.expectEqual(PointerState.pressed_this_frame, state);

    // Held: it becomes plain `pressed` whether or not anybody asked, which is
    // what stops a button firing every frame the mouse is held on it.
    state = state.advance(true);
    try testing.expectEqual(PointerState.pressed, state);
    state = state.advance(true);
    try testing.expectEqual(PointerState.pressed, state);

    state = state.advance(false);
    try testing.expectEqual(PointerState.released_this_frame, state);
    state = state.advance(false);
    try testing.expectEqual(PointerState.idle, state);
}

test "a press and release inside one frame is still seen" {
    // Down and up between two frames: the state passes through
    // `released_this_frame`, so a click faster than the frame rate is not
    // lost - which is the case a naive `was_down != is_down` misses.
    var state: PointerState = .idle;
    state = state.advance(true);
    try testing.expect(state == .pressed_this_frame);
    state = state.advance(false);
    try testing.expect(state == .released_this_frame);
}

test "down and up are the two halves of the four states" {
    for ([_]PointerState{ .idle, .pressed_this_frame, .pressed, .released_this_frame }) |state| {
        try testing.expect(state.isDown() != state.isUp());
    }
    try testing.expect(PointerState.pressed_this_frame.isDown());
    try testing.expect(PointerState.released_this_frame.isUp());
}

test "a pointer answers the four questions a button asks" {
    var pointer: Pointer = .{};
    try testing.expect(pointer.isUp());
    try testing.expect(!pointer.justPressed());

    pointer.state = pointer.state.advance(true);
    try testing.expect(pointer.isDown());
    try testing.expect(pointer.justPressed());
    try testing.expect(!pointer.justReleased());

    pointer.state = pointer.state.advance(false);
    try testing.expect(pointer.isUp());
    try testing.expect(pointer.justReleased());
    try testing.expect(!pointer.justPressed());
}
