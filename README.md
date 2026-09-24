# Fluxion UI

A layout engine that draws nothing. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Ui` | The frame: `open`, `close`, and the three passes that follow. |
| `layout` | What an element asks for - sizing, padding, direction, alignment. |
| `geometry` | Rectangles, and the numbers that place one. |
| `color` | A colour, and the three ways people write one down. |
| `text` | How text is styled, and how the layout finds out how wide it is. |
| `commands` | What a frame comes out as, and the seam a renderer sits on. |

```zig
const ui_lib = @import("fluxion_ui");

var ui: ui_lib.Ui = .init(gpa);
defer ui.deinit();

ui.begin(.init(1280, 720));
{
    ui.open(.{
        .width = .grow,
        .height = .grow,
        .padding = .all(24),
        .gap = 12,
        .background_color = .hex(0x14161A),
    });
    defer ui.close();

    ui.empty(.{ .width = .fixed(220), .height = .grow, .background_color = .hex(0x191C21) });
    ui.empty(.{ .width = .grow, .height = .grow, .corner_radius = .all(10) });
}
for (try ui.end()) |command| draw(command);
```

## What this is

A port of [Ply](https://github.com/TheRedDeveloper/ply-engine)'s layout
engine, whose algorithm is in turn [Clay](https://github.com/nicbarker/clay)'s.
Ply is 0BSD, which asks for nothing at all, including attribution - this
credits it because it is worth reading, not because it has to.

**Nothing here draws, and nothing here opens a window.** A frame comes out as
a flat list of `commands.RenderCommand` - rectangles, borders, scissor pairs -
already ordered back to front, and something else turns those into pixels.
That seam is Ply's, and lifting it is what makes the port tractable: the
layout is arithmetic on rectangles and knows nothing about a GPU.

A renderer is a function that takes `[]const RenderCommand`. That is the whole
contract, and it means the same layout runs against
[Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi), against
[Fluxion WebGL](https://github.com/kisstp2006/fluxion-webgl) directly, or
against a test that counts rectangles on a build server with no display.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-ui
```

```zig
const fluxion = b.dependency("fluxion_ui", .{ .target = target, .optimize = optimize });
exe_mod.addImport("fluxion_ui", fluxion.module("fluxion_ui"));
```

One dependency comes with it:
[Fluxion Math](https://github.com/kisstp2006/fluxion-math), and it is one type
deep - `Vec2`, for a point.

## The three passes

One frame is three phases, and the order is forced rather than chosen:

1. **Fit**, going up. As each element is closed it takes the size its children
   turned out to need. This happens *during* the declaration - `close` does it -
   because by then everything inside is already known.
2. **Grow and shrink**, going down, once per axis. Now a parent has a size, so
   the spare space is shared among the children that asked to grow and any
   overflow is taken back off the largest ones. X first, then Y, because a
   `ratio` height needs a settled width.
3. **Position and emit**, depth first. Every element has a size, so one walk
   puts each box where it goes and writes the commands out back to front.

A grow pass cannot run before its parent has a size, and a parent that fits
its children cannot have one before they do. That is the whole ordering
argument.

## The surface

```zig
ui.begin(.init(1280, 720));                    // the ordinary case
ui.begin(.{
    .size = .init(3840, 2160),
    .scale = 2,                                // twice the size
    .safe_area = .all(48),                     // and keep off the edges
});
```

**`scale` multiplies every length in every declaration** - fixed sizes, minima
and maxima, padding, gaps, corner radii, border widths, floating offsets,
scrollbar thicknesses, font sizes, letter spacing and line heights - and
leaves everything that means a fraction alone. A `percent` width is a share of
a parent that has already been scaled; a `grow` weight is a share of what is
spare; `contain` and `cover` are aspect ratios; a rotation pivot is a fraction
of a box. Multiplying any of those would be a bug rather than a scale.

A game at 3840 by 2160 wants an interface twice the size, not twice as much of
it. Doing that here rather than in the game is the entire point: a game that
multiplies its own numbers gets the ones it remembers and misses the font
sizes, or the corner radii, or the one panel somebody else wrote. It is one
multiplication at the top of `open` and one at the top of `text`, and nothing
downstream of either knows there is a scale at all.

**A scale past what the window can hold overflows**, the same way any other
interface with too much in it does - it runs off the edge rather than piling
up on itself. See [what happens when there is not enough
room](#what-is-here-and-what-is-not).

**`safe_area` insets the root**, in the same pixels as `size` and *not*
multiplied by the scale - a television's overscan and a phone's notch are
facts about the display, and `size` is measured with the same ruler. Anything
floating against the surface is placed inside it too, so a menu anchored to
the right edge is anchored to the right edge of what can actually be seen.

**It moves things; it does not cut them.** Nothing is clipped to the inset, so
a backdrop told to cover the surface still reaches the corners of the screen -
which is what a backdrop is for. The commands still come out in real pixels
and so does the pointer: the safe area is an inset, not a second coordinate
system.

## Ply, line by line

The aim is that somebody who knows Ply can read this and type it without
looking anything up. Everything below is the same call under the same name;
the differences are the ones Zig forces, and there are three of them.

| Ply | Fluxion UI |
| --- | --- |
| `ui.element()` … `.children(\|ui\| ...)` | `ui.open(.{ ... })` … `defer ui.close()` |
| `ui.element()` … `.empty()` | `ui.empty(.{ ... })` |
| `.width(grow!())` | `.width = .grow` |
| `.width(fixed!(200))` | `.width = .fixed(200)` |
| `.width(percent!(0.5))` | `.width = .percent(0.5)` |
| `.width(ratio!(16.0/9.0))` | `.width = .ratio(16.0 / 9.0)` |
| `.width(fit!(100, 400))` | `.width = .fitBetween(100, 400)` |
| `.width(grow!(min: 0, max: 400, weight: 2.0))` | `.width = .growWith(.{ .max = 400, .weight = 2 })` |
| `.layout(\|l\| l.gap(8))` | `.gap = 8` |
| `.layout(\|l\| l.padding(24))` | `.padding = .all(24)` |
| `.layout(\|l\| l.padding((10, 20, 30, 40)))` | `.padding = .trbl(10, 20, 30, 40)` |
| `.layout(\|l\| l.direction(TopToBottom))` | `.direction = .top_to_bottom` |
| `.layout(\|l\| l.wrap().wrap_gap(6))` | `.wrap = true, .wrap_gap = 6` |
| `.layout(\|l\| l.align(CenterX, CenterY))` | `.align_x = .center, .align_y = .center` |
| `.background_color(0x262220)` | `.background_color = .hex(0x262220)` |
| `.corner_radius(12.0)` | `.corner_radius = .all(12)` |
| `.corner_radius((8, 8, 0, 0))` | `.corner_radius = .corners(8, 8, 0, 0)` |
| `.overflow(\|o\| o.clip())` | `.clip = .both` |
| `.overflow(\|o\| o.scroll_y())` | `.clip = .scrollY` |
| `.overflow(\|o\| o.clip_x())` | `.clip = .x` |
| `.overflow(\|o\| o.scroll().scrollbar(\|s\| s))` | `.clip = Clip.scroll.bar(.{})` |
| `ui.scroll_offset()` | `ui.scrollOf("list").?.position` |
| `ui.hovered()` | `ui.hovered()` |
| `ui.pressed()`, `ui.just_pressed()` | `ui.pressed()`, `ui.justPressed()` |
| `ui.just_released()` | `ui.justReleased()` |
| `ui.focused()` | `ui.focused()` |
| `pointer_over(id)` | `ui.isPointerOver("save")` |
| `is_pressed(id)` | `ui.isElementPressed("save")` |
| `bounding_box(id)` | `ui.boxOf("save")` |
| `.floating(\|f\| f.anchor((Right, Top), (Right, Bottom)))` | `.floating = .{ .anchor = .{ .element_x = .right, .parent_x = .right, .parent_y = .bottom } }` |
| `.floating(\|f\| f.attach_root())` | `.floating = .{ .attach = .root }` |
| `.image(asset)` | `.image = .{ .texture = 0 }` |
| `.rotate_visual(\|r\| r.degrees(30))` | `.rotate = .degrees(30)` |
| `.rotate_shape(\|r\| r.degrees(30))` | `.rotate_shape = .degrees(30)` |
| `.on_press(\|\| ...)` | `.on_press = .{ .context = &state, .call = pressed }` |
| `.capture()` | `.capture = true` |
| `.text_input(\|t\| t.placeholder("Name"))` | `ui.textInput(.{ ... }, .{ .placeholder = "Name" })` |
| `{color=red\|text}` in every string | `ui.markup("{color=red\|text}", style)` |
| `ui.get_text_value(id)` | `ui.textValueOf("name")` |
| `ui.set_text_value(id, v)` | `ui.setTextValue("name", v)` |
| `.on_changed(\|t\| ...)` | `if (ui.textChanged("name")) ...` |
| `.on_submit(\|t\| ...)` | `if (ui.textSubmitted("name")) ...` |
| `.preserve_focus()` | `.preserve_focus = true` |
| `.accessibility(\|a\| a.focusable())` | `.focus = .{}` |
| `.accessibility(\|a\| a.focusable().tab_index(2))` | `.focus = .{ .tab_index = 2 }` |
| `.accessibility(\|a\| a.focusable().focus_down("quit"))` | `.focus = .{ .down = "quit" }` |
| Tab and Shift+Tab, read from macroquad | `ui.navigate(.next)`, `ui.navigate(.previous)` |
| The arrow keys, read from macroquad | `ui.navigate(.down)`, and a pad's with `ui.holdNavigation(.down)` |
| Enter and Space on the focus, read from macroquad | `ui.setActivate(down)` |
| `.contain(16.0/9.0)` | `.contain = 16.0 / 9.0` |
| `.cover(16.0/9.0)` | `.cover = 16.0 / 9.0` |
| `.id("save")` | `.id = "save"` |
| `ui.text("Hi", \|t\| t.font_size(32))` | `ui.text("Hi", .{ .font_size = 32 })` |
| `WrapMode::{Words, Newline, None}` | `.words`, `.newline`, `.none` |
| `AlignX::{Left, CenterX, Right}` | `.left`, `.center`, `.right` |
| `AlignY::{Top, CenterY, Bottom}` | `.top`, `.center`, `.bottom` |
| `LayoutDirection::{LeftToRight, TopToBottom}` | `.left_to_right`, `.top_to_bottom` |
| `BorderPosition::{Outside, Middle, Inside}` | `.outside`, `.middle`, `.inside` |

Side by side, the skeleton from Ply's own README:

```rust
ui.element().width(grow!()).height(grow!())
  .background_color(0x262220)
  .corner_radius(12.0)
  .layout(|l| l.direction(TopToBottom).padding(24))
  .children(|ui| {
    ui.text("Hello, Ply!", |t| t.font_size(32).color(0xFFFFFF));
  });
```

```zig
ui.open(.{
    .width = .grow,
    .height = .grow,
    .background_color = .hex(0x262220),
    .corner_radius = .all(12),
    .direction = .top_to_bottom,
    .padding = .all(24),
});
defer ui.close();
ui.text("Hello, Fluxion!", .{ .font_size = 32, .color = .hex(0xFFFFFF) });
```

### The three things Zig changes

**1. `open` and `close` instead of a `children` closure.** Zig has no
closures, so the tree is a block and `defer` guarantees the pairing. This is
the one structural difference, and it buys something back: an early `return`
inside a subtree still closes it.

**2. `layout(...)` is flattened.** Ply nests `gap`, `padding`, `align` and
`direction` behind a builder because a Rust builder needs somewhere to put
them. A Zig struct literal has defaults, so they sit beside `width` and
`height` and the nesting would be punctuation for its own sake.

**3. `align` is two fields.** `align` is a keyword in Zig and cannot be the
name of one, so `align(CenterX, CenterY)` is `.align_x = .center, .align_y = .center`.
The enum values lost their axis suffix because Zig namespaces enums and Rust
globs them into the prelude.

Everything else is the same word.

## Sizing

Five ways to be a size, and the list is the algorithm:

| | What it means |
| --- | --- |
| `.fixed(n)` | This many pixels, and nothing argues. |
| `.percent(f)` | This fraction of the parent's *inside* - after its padding. `.percentPlus(f, px)` adds `px` to it, or takes it away: a share with a margin. |
| `.fit` | As small as the children allow. The default. |
| `.grow` | As large as the parent allows, sharing what is spare. |
| `.ratio(r)` | This multiple of the other axis, once that axis is known. |

Ply spells these with macros - `grow!()`, `fixed!(100)` - because Rust needs
one to give a struct literal default arguments. Zig does not: a declaration
literal resolves against the type the field already has, so there is no macro
anywhere.

**Grow weights** are Ply's addition over Clay:

```zig
ui.open(.{ .width = .growWeighted(2) });   // twice the share of a plain .grow
```

Without them the only way to make one pane twice the width of another is to
know the container's size, which is exactly what `grow` exists to avoid. Two
of Ply's rules about them are kept exactly, and both are tested:

- **A weight of zero is `fit`**, not "grows by nothing". An element that took
  no share but still counted as growable would keep the spare space away from
  its siblings, which is the opposite of what writing zero asks for.
- **A negative weight is a mistake** and trips an assertion, rather than
  producing a layout that leans.

**`contain` and `cover`** hold the resolved box to an aspect ratio *after* the
layout has run, so a picture is letterboxed inside the room it was given
without moving anything beside it. That is what makes them different from
`.ratio` sizing, which takes part in the sharing out of space.

## Text

A layout engine cannot measure text. How wide `Hello` is depends on a font
file, a size, and a rasteriser's opinion about rounding - none of which
belongs in a library that only knows about rectangles. So the layout asks, and
a `text.Measurer` answers:

```zig
ui.setMeasurer(.monospace(0.5, 1.0));      // for a test, or a terminal
ui.text("Hello, Fluxion!", .{ .font_size = 32, .color = .hex(0xFFFFFF) });
```

That is the same indirection Ply has - it holds a `measure_text_fn` - and it
is worth keeping: a program measures with
[Fluxion Font](https://github.com/kisstp2006/fluxion-font), with a bitmap
font, or with the monospace measurer, and the layout is identical in all
three. The adapter for a real font is fifteen lines, and
`examples/prose.zig` is all fifteen of them.

**The string is copied**, so a label formatted into a stack buffer a line ago
is safe to hand over. Ply copies too, into a fresh string per element per
frame; this is one buffer, cleared and refilled, so a settled interface stops
allocating for it.

**Text is what makes the shrink pass mean anything.** Every other kind of
element has a minimum equal to its content and so cannot give way. A paragraph
can: it is as wide as it would be unbroken and as narrow as its longest word,
and everything between those is a place the layout may put it. That is why the
passes run in the order they do -

1. size along x, so every paragraph knows its width,
2. **wrap**, so every paragraph knows how many lines it is,
3. **propagate the heights**, so the boxes round them grow,
4. size along y.

Getting steps two and three the wrong way round makes a wrapped paragraph
overflow the card drawn round it, which is a bug that only shows on long text.

## Pointing at things

```zig
ui.setPointer(mouse_x, mouse_y, mouse_down);   // once, before `begin`

ui.open(.{ .id = "save", ... });
defer ui.close();
if (ui.hovered()) { ... }
if (ui.justReleased()) { save(); }
```

**The answers are one frame old**, and they have to be. `hovered` is asked
while the tree is being declared, and where an element ends up is not known
until the tree is finished - so it answers from where the element was last
frame. Every immediate-mode interface works this way. It is invisible at sixty
frames a second except in one case: an element that has just appeared, or has
just moved a long way, is not hovered until the frame after.

Four states rather than a boolean, because "went down this frame" and "is
down" are different questions and a button needs both:

| | |
| --- | --- |
| `hovered()` | the pointer is over it |
| `pressed()` | the button went down on it and has not come up |
| `justPressed()` | it went down this frame |
| `justReleased()` | it came up this frame, on the element it went down on |

`justReleased` is the one to hang a button on: dragging in from somewhere else
and letting go does nothing, which is what every other interface does too.

**A clipped-away element is not under the pointer**, whatever its box says.
The hit test intersects every clipping ancestor, so a row scrolled out of a
list does not answer a click at the place it would have been.

`.capture = true` stops the pointer reaching what is behind - a knob inside a
draggable panel wants it, so dragging the knob does not also drag the panel.
`.preserve_focus = true` leaves the keyboard where it is, for a toolbar button
that should not take the caret out of the field beside it.

### Which element is which

Everything that outlives a frame - hover, a press, the focus, a scroll
position, what was typed - is kept against a number, and the number is how an
element is recognised in the next frame.

**A named element is its name**, hashed, wherever it is declared: move it or
wrap it in another box, and everything it had follows it. That is also what
lets `isPointerOver("save")` be asked from anywhere.

**An unnamed one is its parent and its place** among the parent's unnamed
children - the scheme Clay and Ply use, except that only unnamed children are
counted, and runs of text apart from elements. So a badge appearing in the
header, a menu opening or a warning over a list leaves the rest of the page
alone. What does renumber one is another unnamed element appearing before it
in the same parent, or its parent being renumbered; anything whose state has
to survive that wants a name.

### What the pointer looks like

```zig
ui.open(.{ .id = "edge", .cursor = .resize_ew, ... });   // per element
ui.setCursor(.resize_ew);                                // for this frame
const shape = ui.cursor();                               // after `end`
```

The interface is the half that knows the pointer is over a text field; the
window is the half that can draw a cursor. So this works out a shape and hands
it over, and setting it is the program's one line - `examples/window.zig` is
that line. The ten names are
[Fluxion Platform](https://github.com/kisstp2006/fluxion-platform)'s, so the
switch between them is a switch and not a table.

**The innermost element under the pointer that named a shape wins**, so a
resize handle inside a panel is not overruled by the panel. **A text input
asks for `.ibeam` without being told to**, and a declaration that names
something else still beats it. Everything else is an arrow: a hand over
anything clickable is the web's convention rather than a desktop's, so an
element that wants one says `.pointing_hand`.

`setCursor` beats the lot for the rest of the frame, which is what a drag
needs - a window edge being pulled keeps its shape while the pointer is
halfway across the screen, with no element under it to say so. Ply's version
persists until it is set again; this one lasts a frame, because a shape that
outlived its frame could never be taken back by a tree that works its own out.

### A clock

```zig
ui.tick(dt);                     // once a frame, in seconds, before `begin`
```

Four things need to know how long a frame took, and none of them can find out
for itself: the caret blinks, a second click becomes a double click, a list
let go of carries on coasting, and a scrollbar told to hide itself waits. All
four are in **seconds**, which is where this parts company with Ply. Ply
counts frames, so the same fade is half as long at a hundred and twenty frames
a second as at sixty, and twice as long on a machine having a bad time; a game
already knows its frame time and handing it over once a frame settles all four
at once.

A program that never calls it gets a solid caret, no double clicks, no
momentum and bars that never fade. All four are the same good failure: a
library with no clock does not invent one.

## Clipping and scrolling

```zig
ui.open(.{ .id = "list", .height = .grow, .direction = .top_to_bottom, .clip = .scrollY });
defer ui.close();
// ... thirty rows in a box that holds five ...
```

```zig
ui.scrollBy("list", 0, wheel_delta);        // before the next frame
const scroll = ui.scrollOf("list").?;       // after it
scroll.overflowsY();                        // is there anything to scroll?
scroll.progress().y;                        // where a scrollbar thumb goes
```

**Clipping and scrolling are separate**, and every `scroll` constructor turns
the matching clip on because content that is not cut off has nowhere to scroll
to. An element may clip without scrolling, which is what a fixed-width chip
with a long label wants.

A clip changes three things, and each is a place the layout would otherwise
refuse to overflow:

1. **Its children do not raise its minimum** on the clipped axis, so a long
   list does not make the panel round it un-shrinkable.
2. **Its children are not squeezed** along a clipped main axis. They keep
   their sizes and run off the end - and that overflow *is* the content a
   scroll position moves through. Squeezing it away would leave nothing to
   scroll.
3. **Its children may be larger than it** across a clipped cross axis.

All three are Ply's, and each has a test that fails without it.

The scroll position is **state that outlives a frame**, like what is typed
into a field. A layout is otherwise a pure function of its declaration and a
scroll position cannot be: it is what the reader has done to the page, and
redeclaring the page must not undo it. It is remembered per element - see
[which element is which](#which-element-is-which) - clamped when each frame
ends, so a container whose content shrank is self-correcting, and forgotten
when the element stops being declared.

Positive means the content has moved **up and left**, so a list scrolled to
the bottom has a positive `y`. A renderer never sees it: it is already in the
boxes by the time the commands come out.

Wiring a wheel to `scrollBy` is the program's business, and
`examples/window.zig` is four lines of it.

### Dragging it

```zig
ui.tick(dt);                     // momentum needs to know how long a frame is
ui.setTouch(from_a_finger);      // only `no_drag_scroll` reads this
ui.setPointer(x, y, down);
```

Pressing inside a scroll container and moving takes the content with you, and
letting go leaves it coasting - Ply's arithmetic, and Ply's three numbers: an
exponential decay that reaches under a hundredth in a second, a floor of five
pixels a second below which it is simply stopped, and a filter that believes
four parts of the last frame's speed to one of this one's, so a single
stuttering frame does not throw the list across the screen. Hitting either end
takes the speed with it.

**The innermost container under the pointer is the one that moves**, and only
one that actually overflows takes hold at all - otherwise every press on a
short list would arm a drag that can never do anything.

The wheel has the same question and the same answer:

```zig
if (!ui.scrollHovered(0, notches * -40)) camera.zoom(notches);
```

`scrollBy` needs a name, so a program with two lists has to work out which one
is under the pointer - which is the hit test it already asked for. This is
that answered here, innermost first and **one axis at a time**, so a page that
holds a strip scrolling sideways splits a trackpad swipe between the two. It
returns whether anything moved, so a game can have the wheel the interface did
not want. A list at the end of its travel keeps the wheel rather than handing
what is left to its parent; browsers hand it on, and a page that lurches when
a list reaches its bottom is the worse of the two surprises.

**`no_drag_scroll` is about the mouse.** Ply's flag turns dragging off for a
pointer and leaves it on for a finger, because on a touch screen there is
nothing else; `setTouch` is what tells the two apart, and a program that never
says is taken to be using a mouse.

Momentum needs a `dt`, so a program that never calls `tick` gets a drag that
follows the finger and stops dead when it leaves. That is the honest answer
for a library with no clock of its own.

**One deliberate difference.** Once a drag has moved more than a few pixels it
lets go of whatever it pressed, so a list of buttons dragged and released does
not fire the button under the finger. Ply keeps the press; every touch
platform cancels the tap, and the absence of it reads as a bug rather than as
a decision.

### Scrollbars

```zig
ui.open(.{
    .id = "list",
    .height = .grow,
    .clip = layout.Clip.scrollY.bar(.{}),
});
```

`bar` takes any of the five clip constants and dresses it, because the
scrolling is decided first and the bar is what is drawn on top of it. The
defaults are Ply's: a six pixel half-transparent grey thumb, rounded, with no
track behind it and no fading. Every one of them has a name -
`.bar(.{ .width = 10, .thumb_color = .hexa(0x6E7681B0), .track_color = .hex(0x202020) })` -
and `min_thumb_size` is the one worth knowing about, because two per cent of a
short track is a thumb nobody can grab.

**Only drawn on an axis that both scrolls and overflows**, so turning it on
for a list that turns out to be short costs nothing. The thumb is as long a
share of the track as the window is of the content, and sits as far along it
as the reader has scrolled - both measured against the container's *whole*
box, so a bar runs the full height of a padded container rather than the
height of its inside.

**Dragging the thumb is handled**, from the same `setPointer` everything else
uses, and a press that lands on a thumb belongs to the scrollbar: nothing
underneath it is pressed and the focus stays where it was. `draggingScrollbar`
says whether that is happening, for a program that has its own idea of what a
press means.

```zig
.bar(.{ .hide_after_seconds = 2 })
```

Fades the bar out after that long without moving and brings it straight back
when anything does. Ply's curve exactly - it holds for the whole time, then
fades over a quarter as long again - but in **seconds where Ply counts
frames**, so a fade tuned on one machine is the same fade on a faster one.
The clock comes from [`tick`](#a-clock); a program that never calls it keeps
its bars.

## Markup

```zig
ui.markup("Press {color=red|Escape} to leave", .{ .font_size = 14 });
```

A tag is a brace, a command, a bar, the text it covers, and a closing brace,
and tags nest:

| | |
| --- | --- |
| `{color=red\|...}` | a name, `#RRGGBB`, or `(r,g,b)` in 0..255 |
| `{opacity=0.5\|...}` | multiplied through nesting, not replaced |
| `{hide\|...}` | takes up its room and is not drawn |
| `{shadow_color=black_offset=-0.3,0.3\|...}` | offset in ems, so it scales with the size |

One command per tag, as in Ply. Nesting is how they combine, and it is what
decides which wins: the innermost `color` is the one drawn, while `opacity`
multiplies all the way up.

**The tags come off when the run is declared**, so what the layout measures,
wraps and boxes is the text the reader will see. A tagged label is the width
of its words rather than of its tags, and a line breaks between two words
rather than in the middle of a tag. Ply carries the tags to its renderer
instead, which works because its measurer knows to skip them.

**It is a separate call**, and that is the second departure. Ply turns markup
on for a whole program with a build feature, so every brace in every label has
to be escaped; asking for it a run at a time costs one word and leaves `text`
never surprising.

**Malformed markup keeps the text.** A space inside a tag means it was never a
tag - so `use { x } here` is prose, not a parse error. A `}` with nothing open
is a `}`. A tag left open runs to the end. Ply errors on all three; showing the
reader the text in the wrong colour beats showing them nothing.

### The ones that move

```zig
ui.markup("{wave_a=0.22_s=6|This waves} and {gradient|this runs through colours}", style);
renderer.setTime(seconds);   // once a frame, on the renderer
```

All nine of Ply's, at Ply's defaults and with its argument names: `wave` and
`jitter` move a glyph, `pulse` and `swing` resize and tilt one, `transform`
does all three and does not move, `gradient` colours them, and `type`, `fade`
and `scale` bring them in or take them away over time.

**They reach the renderer rather than being resolved before it.** Where a
letter of a wave sits depends on which letter it is and what time it is, and
the renderer is the only thing here that has ever seen a letter - the layout
works in runs. So the parameters travel on the text command and the per-glyph
arithmetic happens where the glyphs are, on top of the same transform
[rotation](#rotation) put on the instance.

The pen does not move with them: a wave changes where a letter is *drawn* and
not where the next one starts, or the word would stretch and squash as it
went. That is Ply's behaviour and it is the only one that reads.

`type`, `fade` and `scale` need a start time, which the renderer keeps by the
`id` in the tag - so two runs written `{type_in_id=intro|...}` begin together.
Ply panics when one of these is written without `in` or `out`; this reads a
missing one as `in`, which is what somebody who forgot meant.

### Editing it

```zig
ui.textInput(.{ .id = "notes", .width = .grow, .height = .grow }, .{
    .multiline = true,
    .markup = true,
});
```

The cursor moves through the characters the reader sees; the tags are not in
its way. Typing inside a style stays in it, deleting the last character out of
one takes the tag with it, and typing one of the four syntax characters stores
it escaped. `textValueOf` gives back the string with the tags in.

Ply does this by giving every editing method a second `_styled` copy that
converts between visual and raw positions - about a thousand lines. Here the
stripped text is kept beside the raw one with a map between them, so the
movement, the selection and the word boundaries are the same code for both
kinds of field, and only the two places that actually change the string know
markup exists.

One thing to know: an insertion inherits the style to its **left**, as a word
processor does. That means text ending inside a style has no cursor position
outside it, so typing at the end goes on being red. Continuing a style while
writing is wanted more often than escaping one, and Ply buys the choice by
giving the cursor an extra position for every closing brace - at the price of a
right arrow that sometimes does not appear to move.

### Rich text

```zig
ui.richText("{size=28|{b|Credits}}\nMade by {color=#72A7E8|us}, with {img=heart|} ", .{ .font_size = 16 }, .{
    .image = .{ .context = &pictures, .find = Pictures.find },
    .visible = shown,
});
```

Everything `markup` reads, and three tags more: `{b|...}` sets a stretch
heavier, `{size=24|...}` sets it at that many pixels to the em, and
`{img=name|}` puts a picture a line tall where it stands - the whole of what
follows `img=` is its name, underscores and slashes and all, and `find`
answers it. **Each word is a run of its own**, in its own size and font, in
rows that wrap: a paragraph breaks between words however each is set, and a
line's end starts the next one. Words of different sizes sit on a common
bottom, and a wave or a gradient still travels along the whole text.

A heavy stretch is set in `bold_font` where there is one; where there is
not, it is struck twice, the second a pixel or so to the right, which reads
as heavier in any font at any size. **`visible`** says how many characters
show - the rest keep their room and are not drawn - which is dialogue
arriving letter by letter without the words before it moving.

## Rotation

```zig
.rotate = .degrees(-7),          // this element and everything in it
.rotate_shape = .degrees(90),    // only its own box
```

Ply's two, under Ply's names. `rotate` turns the element and its children;
`rotate_shape` turns the element's own drawing and leaves its children where
they were. Both take a `pivot` in fractions of the box - the middle by default
- and `flip_x` / `flip_y`, mirrored before the turn as Ply does it.

**It changes nothing about the layout.** An element takes up the room its
unturned box does and its neighbours do not move, which is Ply's behaviour and
the only sensible one: a badge tilted seven degrees should not reflow the page.

**Turns nest.** A rotated icon in a rotated card is one motion, which is why a
command carries two axes and an origin rather than an angle and a pivot: two
turns about two different pivots compose into the first and not into the
second.

**The pointer follows.** A rotated button is clickable where it was drawn,
because the hit test moves the *pointer* into the element's frame rather than
trying to test a point against a turned rectangle. That is a transpose over the
square of the scale and a subtraction, and it is only the inverse because a
`Transform` here is a turn, a mirror, one scale for both axes and a move - no
shear and no stretch anywhere.

One thing does not turn: **a scissor**. Clipping is axis-aligned in every
graphics API there is, so a rotated element that clips clips by its unturned
box. Ply has the same limitation.

Under the renderer this is six more floats on the instance and two lines of
vertex shader. Only the *position* goes through the motion: the distance field
is still measured in the box's own frame, so a turned rounded corner is still
round and its edge is still one pixel wide. Ply instead renders the subtree to
an offscreen target and draws that target rotated, which costs a pass and
resamples the text; this costs neither.

## Size and opacity

```zig
.scale = .by(1.2),       // this element and everything in it, about its middle
.opacity = 0.5,          // this element and everything in it, half there
```

Two more that go the way `rotate` does: onto what an element and everything
inside it draws, and never into the layout. **A size** grows or shrinks about
a `pivot` in fractions of the box, the middle by default, and composes with a
turn and with the sizes and turns around it; the pointer still finds the
element where it was drawn, and one shrunk to nothing is found nowhere. One
factor for both axes, so a rounded corner stays round - its antialiased edge
grows with it. **An opacity** multiplies the alpha of every colour the element
and its children draw, its border and its text among them, times its
ancestors'; at nought nothing of it reaches the list, though the pointer still
finds it. It is worked into the colours as the commands are made, so a
renderer draws a fading panel without knowing it fades.

A float declared inside an element - `attach = .parent` - is inside it on
screen as well, so it turns, grows and fades with it. One attached to the
root, or to another element by id, does not.

## Images

```zig
renderer.setTextures(&.{sheet});          // once, on the renderer

ui.empty(.{
    .width = .fixed(34),
    .height = .fixed(34),
    .corner_radius = .all(17),            // a circle, cut out of the picture
    .image = .{ .texture = 0, .source = .init(0, 0, 0.5, 1) },
});
```

**A number, not a texture.** The layout half of this library has never heard
of a GPU and does not want to: a command carries the number, and
`Renderer.setTextures` is where the number becomes a texture. A number with no
texture behind it draws the background and nothing else - a missing picture
rather than a crash.

**It does not size the element.** Nothing here knows how many pixels the
texture is, which is Ply's position too, so a picture is as big as it was
declared. `contain` and `cover` hold it to its own proportions inside the room
it was given.

**A picture is cut to the same rounded box a rectangle is**, so a corner
radius of half the side gives a circle, and an image inside a scroll container
is clipped like everything else.

Two things Ply does not have, both nearly free and both needed by any real
interface:

- **`source`** names a part of the texture, in fractions from zero to one - so
  one sheet holds a hundred icons. Everything drawn from one sheet stays in
  one draw call, because what breaks the batch is changing the *texture*, not
  changing the picture.
- **`tint`** is multiplied in, so one white icon is every colour of icon.

Under the renderer, a picture is one more instance of the same quad with a
different number in it: shapes are the distance field, glyphs are one channel
of the atlas, pictures are four channels of a texture. What breaks a batch is
the texture that has to be bound - so a page of shapes, labels and icons from
one sheet is three draws rather than one per icon.

## Wrapping

```zig
ui.open(.{ .id = "tags", .width = .grow, .height = .fit, .gap = 6, .wrap = true, .wrap_gap = 6 });
defer ui.close();
// ... a tag at a time ...
```

Children that do not fit start a new line, along the main axis - a
`left_to_right` element wraps into rows and a `top_to_bottom` one into
columns. `gap` is still the space along a line; `wrap_gap` is the space
between them.

**It only bites when the main axis is constrained.** A row that fits its
content has room for all of it and never wraps; one that is `.fixed`, `.grow`,
`.percent`, or squeezed by its parent wraps at its edge. That last case is
what makes a wrapping row possible at all: a row's smallest size is normally
the sum of its children, and one that cannot be squeezed can never be narrow
enough to wrap - so **a wrapping element's minimum is its widest single
child** instead. A child too wide even for that gets a line of its own and
overflows, which is the only answer that terminates.

**A growing child is broken on by its minimum**, not by the size it will grow
to. Where the lines fall decides how much room each one has to share out, and
how much a child grew depends on that; asking the grown size first would be a
loop. Ply does the same, and it means a row of `.grow` children with no
minimum never wraps - none of them is asking for anything.

**Each line is its own row.** The space is shared out per line, so a line with
room to spare does not stretch a child on the line below it; each line is
aligned along the main axis on its own, so a short last row under a centred
wrap sits under the middle rather than the left; and a child is aligned across
*its* line rather than across the whole element.

One shape does not settle: **a wrapping column whose width is `.fit`**. The
extra columns are known only once the heights are shared out, by which time
the widths are decided and its ancestors have made room for one column. Give
such a column a width and it behaves. A row has neither problem, because the
axis it wraps along is the one that is settled first.

## Floating

```zig
ui.open(.{ .id = "button", .width = .fit, .height = .fit });
{
    defer ui.close();
    ui.text("Menu", .{ .font_size = 13 });

    if (ui.isPointerOver("button") or ui.isPointerOver("menu")) {
        ui.open(.{
            .id = "menu",
            .width = .fixed(170),
            .height = .fit,
            .floating = .{ .anchor = .below, .offset = .{ .x = 0, .y = 6 } },
        });
        defer ui.close();
        // ... the items ...
    }
}
```

**A floating element is not its parent's child for layout purposes.** Its
siblings are placed as though it were not declared, it adds nothing to the
parent's fit size, and nothing moves when it appears or goes away - which is
the whole point. A menu, a tooltip, a dropdown and a modal are all this one
feature, and every one of them has to be able to appear without the page under
it shifting.

Where it goes is two anchor points and an offset: a point on the element is put
on a point of whatever it is attached to. `.anchor = .below` is the element's
top left onto the target's bottom left; `above`, `after`, `before` and
`centered` are the others worth having a name. Anything else is spelt out:

```zig
.anchor = .{ .element_x = .right, .parent_x = .right, .parent_y = .bottom }
```

**Or anywhere along the two**, as fractions: `.fractions = .{ .element_x =
0.5, .target_x = 0.25 }` puts the element's middle a quarter of the way
across its target. With `.width = .percentPlus(0.5, -20)` that is a box held
between two points of its parent, a margin inside them - what a game's
anchors come to.

**What it attaches to** is `.parent` (the element it was declared inside),
`.root` (the whole surface, for a modal), or `.id` with a name. A name is
resolved once the whole tree is laid out, so it may point at something declared
*later* - Ply resolves as the element is declared and cannot. The name itself
is read as the float is declared, though, so it may be formatted into a buffer
that the next one reuses.

**It grows into its target.** A floating element has no parent to grow into, so
`.grow` fills whatever it is anchored to and `.percent(0.5)` is half of it -
which is what makes a dropdown the width of the control it drops from.

**It is drawn over the page**, in `z_index` order and in declaration order
within one, and the pointer finds it first. Ply's `clip_by_parent` is
`.clip = true`, which cuts it off at the target's edge.

One thing worth knowing: **a floating element ends the chain the pointer walks
up**. Standing on the menu does not count as standing on the button it hangs
off, because on screen it is not inside it - the same reason `capture` stops
the walk. A hover menu asks about both, as the example above does.

## Over a game

Two things a program needs when the interface is not the only thing on the
screen.

**Draw on top of what is there.** `Renderer.draw` takes `?Color`, and `null`
means load rather than clear - so a game can draw its scene, then its
interface, into one surface. A `Color` still coerces on its own, so a program
that only ever draws an interface says nothing new.

```zig
try renderer.draw(target, size, scene_commands, .black);   // clears
try renderer.draw(target, size, ui_commands, null);        // draws on top
```

**Ask whether the interface wanted that.** Dear ImGui calls these
`WantCaptureMouse` and `WantCaptureKeyboard`, and every program that puts an
interface over a world needs both: when a button is under the cursor, exactly
one of "press the button" and "fire the gun" should happen.

```zig
if (ui.wantsPointer()) return;    // the interface is having this click
if (ui.wantsKeyboard()) return;   // somebody is typing, so W means W
```

`wantsPointer` is true where the interface either **drew** something - a fill,
a border, a picture - or **asked** to be clicked: a callback, a text field, a
`capture`, a list that scrolls. A transparent root over a game does not count,
which is the whole point, because a heads-up display is mostly nothing. An
application whose root has a background wants the pointer everywhere, which is
also right.

`wantsKeyboard` is true only when a **text input** has the focus. A focused
button does not take W away from the game.

Both answer from where things were when the last frame finished, like every
other pointer question here - so a game asks them after the interface's frame
and before its own input runs.

## Callbacks

```zig
fn pressed(context: ?*anyopaque, event: ui.Callback.Event) void {
    const count: *u32 = @ptrCast(@alignCast(context.?));
    count.* += 1;
    _ = event;
}

ui.empty(.{ .id = "button", .on_press = .{ .context = &count, .call = pressed } });
```

Ply's five, under Ply's names: `on_hover`, `on_press`, `on_release`,
`on_focus` and `on_unfocus`. Ply writes `.on_press(|| count += 1)` and Rust
captures `count`; Zig has no closures, so what would have been captured is
passed as the context and the callback casts it back - the same shape
`Measurer` already has.

**They are called when the frame is over**, from `end`, after the commands are
built. That is where Ply calls its own and it is the only point that can be
right: a callback changes the program's state for the *next* frame rather than
for the one being handed over. What a callback must not do is declare
elements, because the frame it would declare them into has already gone.

`on_hover` fires every frame the pointer is over, not the frame it arrives -
Ply's meaning of the word, and the one [`hovered()`](#pointing-at-things)
answers. `on_release` is told whether the pointer was still on the element
when the button came up, which is the difference between a click and a change
of mind. A press walks the chain, so a card wrapping a label hears about a
press on the label unless it `capture`s.

**Asking is usually the better shape.** `hovered()`, `pressed()` and
`justReleased()` answer in the branch that drew the button, where the state
they are about already is. Callbacks are for the times that is not where the
decision lives - a widget whose *owner* wires up the behaviour rather than
whatever draws it - and for the focus pair, which polling cannot answer at
all: nothing else can tell you the frame an element *lost* the keyboard.

## The focus, from a keyboard or a pad

```zig
ui.open(.{ .id = "play", .focus = .{} });     // this one takes the focus
defer ui.close();
if (ui.justReleased()) play();               // a click, Enter, or a pad's A
```

```zig
if (tab) _ = ui.navigate(if (shift) .previous else .next);
if (arrow_down) _ = ui.navigate(.down);      // and up, left and right
ui.holdNavigation(pad_direction);            // a d-pad or a stick, once a frame
ui.setActivate(enter or space or pad_a);     // once a frame, like setPointer
```

A game's interface has to work with nothing but a pad, and an
application's with nothing but a keyboard. The library still never sees a
key: what arrives is what the key *meant*, which is the bargain the [text
input](#the-keyboard-is-the-programs) already makes.

**An element takes the focus when it says so**, with `.focus = .{}`.
Nothing is worked out from a callback: an immediate-mode button is usually
an element whose branch asks `justReleased()`, and there is nothing on it to
see. A text input takes the focus without being told to.

**Tab walks them in the order they were declared** and comes round at the
ends. `.focus = .{ .tab_index = 2 }` puts an element before all of those
without one, lowest number first - Ply's rule, and the browsers'. From a
panel somebody clicked, Tab goes on from where the panel was declared.

**Tab can go where the focus names**, too: `.focus = .{ .next = "first" }`
sends the last field of a form back to its first rather than on, and
`.previous` is Shift+Tab's. **`.tab_stop = false`** keeps an element out of
Tab's walk and the arrows' - it takes the focus from a press on it, or from
`setFocus`, and from nothing else: a list whose rows are clicked and walked
with the list's own keys.

**The arrows go to the element that way.** The one the focus names, if it
names one - `.focus = .{ .down = "quit" }`, Ply's `focus_down`, read as it is
declared like every name here - and otherwise the nearest, among the boxes
as they were drawn last frame:

- only what is further that way counts, by its middle and by its far edge,
  so something level with the focus is never a step down;
- what shares the focus's band - its column for up and down, its row for
  left and right - comes first, and the smallest gap wins, so a menu steps
  to the button directly below even when one beside it is nearer;
- only when the band is empty does the rest count, by the gap plus twice the
  distance across;
- ties go to the one nearer the middle, and then to the one declared first.

A turned element is measured where it was drawn. A row scrolled out of its
list can be reached - otherwise a pad could never walk a long list - and one
that a clip which does not scroll has cut off cannot. With nothing further
that way the focus stays where it is, and `navigate` says so, so the press is
the game's to use: `if (!ui.navigate(.left)) previousTab();`.

**A pad's direction is a level**, and `holdNavigation` turns it into steps:
one when it is pressed, another 0.35 seconds later and one every 0.08 after
that, on the clock `tick` keeps - `setRepeat` changes both. Never more than
one a frame, and a hitch in the game does not come back as a burst of rows.
A keyboard repeats on its own, so every arrow key event, repeats and all, is
one `navigate`.

**The key that presses is a level, not an event**, and it goes through the
pointer's four states: `pressed()`, `justPressed()`, `justReleased()` and the
`on_press` and `on_release` callbacks answer for it as they do for a click,
about whatever had the focus when it went down. A button cannot tell which of
the two pressed it. Move the focus away while the key is down and letting go
presses nothing, which is the keyboard's way of dragging off a button.

**A click focuses the button, not the label in it**: the innermost element
under the pointer that takes the focus gets it, unless something on the way
there asks to `preserve_focus`. With nothing there that takes the focus, the
innermost element gets it, as it always has.

Answered from the last frame, like the pointer: an element that has just
appeared cannot be tabbed to until the frame after.

## Text input

```zig
ui.textInput(
    .{ .id = "name", .width = .grow, .height = .fixed(32), .padding = .xy(10, 7) },
    .{ .placeholder = "Your name", .drag_select = true },
);

const typed = ui.textValueOf("name").?;
if (ui.textSubmitted("name")) send(typed);
```

Two arguments, like `text`: the box is a declaration like any other, and the
config is only what makes it editable. Give it a **width** - a `.fit` width is
the padding and nothing else, because a box that resized itself as the reader
typed would be unusable. A `.fit` height is one line, which Ply does not do and
which stops an input nobody gave a height from being an invisible box the
reader can focus and type into and never see.

What it holds outlives the frame, like a scroll position, and is forgotten when
the element stops being declared.

### The keyboard is the program's

This library has no platform layer and never will, so it never sees a key. What
it takes is what a key *meant*:

```zig
ui.tick(dt);                                   // the cursor blinks on this
ui.setShift(shift_held);                       // for shift-clicking
ui.setPointer(x, y, button_down);

_ = ui.textAction(.moveTo(.left, shift));      // Left, or Shift+Left
_ = ui.textAction(.backspace_word);            // Ctrl+Backspace
ui.typeText("á");                              // a character event
if (ui.textAction(.copy)) |taken| clipboard.set(taken);
_ = ui.textAction(.{ .paste = clipboard.get() });
```

Ctrl against Cmd, key repeat, dead keys and the layout the reader actually has
are all decisions a program makes and a layout library cannot. What is ported
is everything after that decision, which is where the behaviour lives.
`examples/window.zig` has the whole binding, in about forty lines: the arrows
and the deletions by where the key is, the letters by the virtual key
fluxion-platform names them with - Ctrl+Z is the Z the reader can see, which
on a German or Hungarian keyboard is where a US one has Y - and AltGr, which
Windows reports as Ctrl and Alt together, not taken for Ctrl.

**Home and End are decided here, not by the caller.** `.start` and `.end` mean
the line in a multiline input and the whole text in a single-line one, so one
binding is right for both; `.text_start` and `.text_end` are Ctrl+Home and
Ctrl+End. Copy and cut hand the selected text back rather than reaching for a
clipboard, because there is no clipboard to reach for.

**Where the cursor is goes the other way**, to the platform's text input.
`wantsKeyboard` says somebody is typing, which is what raises a phone's
keyboard; `caret` says where, which is what puts an input method's composition
and its candidates beside the text rather than over it.

```zig
try window.setTextInput(ui.wantsKeyboard());
if (ui.caret()) |at| try window.setTextInputArea(.{
    .x = @intFromFloat(at.x),
    .y = @intFromFloat(at.y),
    .width = @intFromFloat(@ceil(at.width)),
    .height = @intFromFloat(@ceil(at.height)),
});
```

It is the box the cursor is drawn in, in the surface's pixels, as the last
frame drew it - and still there while the blink has the cursor hidden, because
an input method wants the place and not the pixels. It is null when nothing is
being typed into, from the moment the focus leaves rather than a frame later.

### What it does, and where it differs

Ply's plain editing model, ported whole: character, word and line movement with
shift extending the selection; the four deletions, and Ctrl+Delete taking the
space after the word as well as the word; insertion with a length limit counted
in characters; undo and redo, where typing a word is one undo and a paste is
its own; click to place the cursor, double click to select a word, drag to
select; the blink, on Ply's 1.06 second clock; and both scroll offsets, which
keep the cursor in view as it moves.

Two deliberate differences:

- **Positions are byte offsets**, not Ply's character counts. Ply calls
  `text.chars().count()` in almost every method, which walks the string; a byte
  offset is what a Zig slice already wants. Nothing a reader sees changes - the
  cursor still steps one character at a time through "árvíztűrő", and
  `max_length` is still characters.
- **Up and down keep the column they started from.** Ply's plain path
  recomputes it at every step, so passing through a short line forgets it. Ply
  has the field for this and its comment, and only its styled path uses it.

## The renderer

Optional, and a separate module. The library's own output is a command list;
this is one ready-made consumer of it, for programs that do not want to write
their own:

```zig
const render = @import("fluxion_ui_rhi");

var renderer: render.Renderer = try .init(gpa, &device, &face);
defer renderer.deinit();

try renderer.draw(.{ .surface = surface }, size, try ui.end(), .hex(0x14161A));
try device.present(surface);
```

**One instanced draw for the whole frame.** Every rectangle, every border and
every glyph is the same unit quad under a different set of per-instance
numbers, and the fragment shader decides what it is looking at - because the
three things a UI draws are the same thing:

| | What it is |
| --- | --- |
| A rectangle | A rounded box, filled. |
| A border | A rounded box with a smaller one cut out of it. |
| A glyph | A rectangle whose alpha comes from the atlas. |

So there is one pipeline, one shader, one texture and one buffer, and the only
thing that breaks a batch is a scissor rectangle - which an interface changes
a handful of times a frame, not a thousand. A window full of controls is one
draw call, and a thousand more boxes is still one.

The shape comes from a signed distance field: `roundedBox` is negative inside
and positive outside and the value is the distance in pixels, so `0.5 - d`
clamped to zero and one is a one-pixel antialiased edge that needs no
multisampling and no extra geometry. A border is the same field twice, with
the inner one subtracted.

Glyphs live in one `r8_unorm` atlas, packed on shelves and keyed by face, glyph
*and* size together - the same letter at 12 pixels and at 13 is two different
pictures, and there is no scaling one into the other that does not look wrong.
An atlas that fills up is emptied and the frame built again, so glyphs at sizes
nothing draws any more cannot run it out of room for good.

**More than one font.** A text run's `font` is an index into the renderer's
faces, which are `init`'s one until `setFaces` says otherwise:

```zig
try renderer.setFaces(&.{ &interface_face, &code_face });   // .font = 1 is code
```

The first is the default, and an index past the end is drawn in it. Putting
another face at a slot forgets that slot's glyphs; a font read again in place
keeps its pointer, so it says so with `renderer.forgetFace(slot)`. The measurer
the layout used has to measure each run in the same face - the same table in
the same order - or lines break where the text is not.

Both dependencies are lazy. A program that only lays out, or that brings its
own renderer, fetches neither.

**Both backends are proved on a GPU.** The shader is written twice - GLSL for
OpenGL, HLSL for Direct3D - and a pair written side by side where only one of
them is ever run is a trap: a semantic that does not match, a constant buffer
packed differently, a `float2` where a `float4` was expected. None of those is
an error anywhere; all of them are a blank window. So there are two tests, one
per backend, each rendering a frame into a texture and reading the pixels back.

They draw an orange square rather than a white one, on purpose: white is the
same number in every channel and would pass just as happily out of a backend
that handed the bytes back as BGRA. Orange does not, so the two backends are
held to the same channel order as well as the same picture.

The Direct3D test needs no window at all - a device is made without one - so
it runs anywhere Windows does. The OpenGL one opens a hidden window and skips
where there is no display.

```bash
zig build example-window                     # OpenGL
zig build example-window -- --backend d3d11  # Direct3D 11
```

**The third backend is a browser's.** Built for `wasm32-freestanding`,
fluxion-rhi draws through WebGL 2 on the page's canvas, and the renderer hands
it the same shader again, as GLSL ES 3.00 - fluxion-shader writes all three
languages from the one source. Off wasm the WebGL backend runs against
fluxion-webgl's stub, which compiles anything and draws nothing, so the test
for it checks the one thing a machine without a browser can: that WebGL is
given a shader in a language it reads. Without one the renderer is refused at
`init`, and the page stays blank.

## Colour

Four floats from zero to one, which is what a GPU takes. Ply keeps the same
four floats from zero to *255*, which is macroquad's convention showing
through; the division happens once, here, and `hex` is the constructor to
reach for because hex is what a designer hands over.

```zig
.background_color = .hex(0x262220),
.background_color = .oklch(0.7, 0.14, 250),   // same lightness at every hue
```

## Where the origin is

**Top left, y downwards.** What every UI does, what
[Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) already settled on
for viewports and scissor rectangles, and what a renderer built on either does
not have to think about again. OpenGL's bottom-left origin is a backend's
problem.

## What is here, and what is not

Checked against Ply's own declaration surface - `ElementBuilder`,
`LayoutBuilder`, `OverflowBuilder`, and the methods on `Ply` itself - rather
than from memory.

### Here

| | |
| --- | --- |
| **Sizing** | `fit`, `grow` with weights, `fixed`, `percent`, `ratio`, with minima and maxima |
| **Layout** | direction, padding, gaps, alignment on both axes, `contain` and `cover`, wrapping |
| **The surface** | a scale that multiplies every length in the tree, and a safe area that keeps the root off the edges of a television |
| **Painting** | background colours, corner radii, borders on any side with three positions, z-index |
| **Images** | a texture number, a source rectangle for sheets, a tint, and the same rounded box a rectangle gets |
| **Rotation** | of an element and its children or of its own box alone, with a pivot and flips, nesting, and a hit test that follows |
| **Size and opacity** | of an element and its children, about a pivot, nesting with turns, carried to the floats inside it |
| **Text** | a `Measurer` seam, word wrapping, hard newlines, per-line alignment, letter spacing, line height |
| **Markup** | `{color=red\|...}` with nesting, plus `opacity`, `hide` and `shadow` - parsed before the layout sees it |
| **Rich text** | words in their own sizes and weights, pictures among them, rows that wrap between words, and as many characters shown as asked |
| **Animated text** | all nine of Ply's: `wave`, `pulse`, `swing`, `jitter`, `transform`, `gradient`, `type`, `fade` and `scale` |
| **Clipping and scrolling** | per axis, by wheel - by name or by whatever is under the pointer - by dragging the content, and by the bar, with momentum and with the position remembered between frames |
| **Scrollbars** | a draggable thumb, an optional track, a minimum thumb size, and a fade after a quiet spell |
| **Pointing** | hit testing, hover, press, release and focus, with `capture`, `preserve_focus`, clip-aware picking, `wantsPointer` for a program that has its own use for a click, and a cursor shape to hand the window |
| **Callbacks** | `on_hover`, `on_press`, `on_release`, `on_focus` and `on_unfocus`, called when the frame is over |
| **The focus from a keyboard or a pad** | `.focus` on a declaration, a Tab order with `tab_index`, the arrows and a pad's d-pad going to a named neighbour or the nearest element that way, a held direction that repeats on `tick`'s clock, a key that presses what has the focus the way a click does, and a click that focuses the button rather than its label |
| **Floating** | out of the flow, anchored to a parent, an element by name, or the surface - at an edge, the middle, or any fraction along - with an offset, a z-index and optional clipping |
| **Text input** | selection, the four deletions, word movement, undo and redo, click, double click and drag, password, multiline, markup, and the caret's place for an input method |
| **A renderer** | optional, over Fluxion RHI: one instanced draw a frame, an SDF for the shapes, a glyph atlas for the text, and a pass that can draw over a scene rather than instead of it |

### Only in Ply

Everything below is something Ply does and this does not. The order is roughly
the order it is worth doing in.

| | What it is, and what it needs |
| --- | --- |
| **The rest of keyboard navigation** | A ring drawn round the focus when the keyboard put it there; the arrow keys scrolling the list under the pointer when there is nowhere to move the focus; and PageUp, PageDown, Home and End scrolling it too. Tab, `tab_index`, the arrows and the key that presses are [here already](#the-focus-from-a-keyboard-or-a-pad). |
| **`passthrough`** | The opposite of `capture`: an element the pointer goes straight through, so a decoration over a button does not swallow the click. |
| **TinyVG** | Ply can hand a vector image straight to `.image(...)` and rasterise it. Here a picture is a texture, and turning TinyVG into one is somebody else's pass. |
| **Shaders and effects** | `.effect(...)` and `.shader(...)`: a fragment shader per element, with Ply's own build step behind it. This renderer is one pipeline and one draw call by design, and a shader per element is a pipeline per element - so this is not a missing feature so much as a different renderer. A program that wants it can consume the command list itself. |
| **Smooth scrolling** | Ply also animates *towards* a target over a duration, so a wheel notch glides rather than jumps. A flick coasts here; a notch still arrives at once. |
| **`between_children` borders** | A line drawn between one child and the next, without an element per separator. |
| **Easing and lerp** | Ply's `easing.rs` and `lerp.rs`: a curve library and a "move this towards that" helper, for animating anything. |
| **A debug view** | `set_debug_mode`: Ply draws the tree beside the interface with every box and its numbers. |
| **Culling** | `set_culling`: dropping commands that fall outside the surface before they reach the renderer. |
| **A measure cache** | Ply remembers the width of words it has measured. This measures every time, which is the same answer more slowly. |
| **Input methods** | Where the caret is, for the platform to open an input method's window beside, is [here already](#the-keyboard-is-the-programs). What is missing is the composition drawn inline, in the field, while Japanese or Chinese is being composed: that needs preedit events this library never sees, and `text_input.Action` has room for them. |
| **Accessibility, networking, audio, storage, jobs** | Out of scope by decision, not by accident. Ply's are bound to its own subsystems; these belong to the fluxion ones. |

Two deliberate departures worth knowing about, both explained where they are
made: [colours are 0..1 floats](#colour) rather than Ply's 0..255, and the
keyboard reaches a text input as [an action rather than a
key](#the-keyboard-is-the-programs).

A container too small for its fixed children still overflows rather than
squeezing them, which is the right answer: a silent squeeze hides the problem,
and overflow is what a scroll container is for. What *can* give way is a
paragraph, down to its longest word - see [Text](#text).

**And no further, and never in height.** This is another place where this
parts company with Ply, and the one where Ply has a bug. A paragraph is the
one thing that draws outside its box: shrink it and the text does not get
smaller, the box does - so a line that no longer fits is drawn over whatever
comes next. Ply gives a
text element a minimum of one line and its longest word, keeps that minimum
after wrapping, and lets the vertical pass squeeze a three-line paragraph back
to one - which is why an interface with too little room for its text in Ply
overlaps rather than overflows. Here a paragraph's minimum height becomes its
wrapped height the moment the wrap is known, a run that breaks only at its own
newlines is as narrow as its widest line rather than its widest word, and a
container that grows is asked again for both after wrapping rather than only
the ones that fit their content. The interface runs off the edge instead,
which is the same answer every other overflow gets.

It is the failure mode a `scale` makes easy to reach - twice the interface in
the same window - so it is worth knowing which of the two you are looking at.

## Examples

```bash
zig build example          # an application shell, printed as draw commands
zig build example-prose    # a paragraph measured with a real font and drawn
zig build example-window   # the whole stack on a real GPU, in a window
```

```
1280x720, 19 commands

  rectangle (0.0, 0.0) 1280.0x720.0 #14161A
  rectangle (0.0, 0.0) 1280.0x40.0 #1D2026
  rectangle (12.0, 14.0) 12.0x12.0 #53A3F2
  ...
  rectangle (240.0, 60.0) 494.0x616.0 #232830
  rectangle (750.0, 60.0) 247.0x616.0 #232830
  rectangle (1013.0, 60.0) 247.0x616.0 #232830
```

Three cards weighted two to one to one, in a pane nothing in the program knows
the width of. No window, no GPU, and the same declaration handed to a renderer
draws the same boxes.

## Build

```bash
zig build test        # the suite
zig build example     # the shell, printed
zig build docs        # API docs into zig-out/docs
```

The tests come in three layers. The layout ones are layouts with known right
answers, checked against the boxes that came out, measured with a monospace
measurer so a wrapping bug is a number wrong by a whole character. The
renderer ones run against Fluxion RHI's `none` backend, which validates every
call and draws none of them, so the instances and the scissor batches are
checked on a machine with no GPU. And two of them open a hidden window, render
a frame into a texture and read the pixels back - because a shader that does
not compile, an attribute at the wrong offset and a viewport the wrong way up
all pass everything else and produce a blank window. On a machine with no
display they skip.

The renderer is built for `wasm32-freestanding` as well, where fluxion-rhi
draws through WebGL. That build is compiled and never run - there is no page
to run it in - because none of the tests see that target, and a call with
nowhere to go in a browser, the way `std.debug.print` has none, is only found
by compiling for one.

The layout tests are layouts with known right answers, checked against the boxes that
came out - which is the only way to test a layout engine, because an
intermediate size is not worth asserting on when the next pass is allowed to
change it. The example carries its own: that the panes tile the window with no
gaps, that the sidebar keeps its width while the content takes the rest, and
that the weighted cards come out two to one to one at every window size.

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: BSD-2-Clause`

[BSD 2-Clause](LICENSE) - permissive, and short enough to read in a minute.
The two obligations are that the copyright notice travels with the source,
and that a binary built from it reproduces the notice in its documentation.

Fluxion libraries are licensed by layer: the foundation is CC0, the engine
infrastructure is BSL-1.0, and what builds on top of it - this, and
[Fluxion Font](https://github.com/kisstp2006/fluxion-font) - is BSD.
[Ply](https://github.com/TheRedDeveloper/ply-engine), which this is a port
of, is 0BSD and asks for nothing.
