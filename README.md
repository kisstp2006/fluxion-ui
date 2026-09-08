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
| `.layout(\|l\| l.align(CenterX, CenterY))` | `.align_x = .center, .align_y = .center` |
| `.background_color(0x262220)` | `.background_color = .hex(0x262220)` |
| `.corner_radius(12.0)` | `.corner_radius = .all(12)` |
| `.corner_radius((8, 8, 0, 0))` | `.corner_radius = .corners(8, 8, 0, 0)` |
| `.overflow(\|o\| o.clip())` | `.clip = .both` |
| `.overflow(\|o\| o.scroll_y())` | `.clip = .scrollY` |
| `.overflow(\|o\| o.clip_x())` | `.clip = .x` |
| `ui.scroll_offset()` | `ui.scrollOf("list").?.position` |
| `ui.hovered()` | `ui.hovered()` |
| `ui.pressed()`, `ui.just_pressed()` | `ui.pressed()`, `ui.justPressed()` |
| `ui.just_released()` | `ui.justReleased()` |
| `ui.focused()` | `ui.focused()` |
| `pointer_over(id)` | `ui.isPointerOver("save")` |
| `is_pressed(id)` | `ui.isElementPressed("save")` |
| `bounding_box(id)` | `ui.boxOf("save")` |
| `.capture()` | `.capture = true` |
| `.preserve_focus()` | `.preserve_focus = true` |
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
| `.percent(f)` | This fraction of the parent's *inside* - after its padding. |
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

The scroll position is **the one piece of state that outlives a frame**. A
layout is otherwise a pure function of its declaration and a scroll position
cannot be: it is what the reader has done to the page, and redeclaring the
page must not undo it. It is remembered per element, clamped when each frame
ends - so a container whose content shrank is self-correcting - and forgotten
when the element stops being declared.

Positive means the content has moved **up and left**, so a list scrolled to
the bottom has a positive `y`. A renderer never sees it: it is already in the
boxes by the time the commands come out.

Wiring a wheel to `scrollBy` is the program's business, and
`examples/window.zig` is four lines of it.

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

Glyphs live in one `r8_unorm` atlas, packed on shelves and keyed by glyph *and*
size together - the same letter at 12 pixels and at 13 is two different
pictures, and there is no scaling one into the other that does not look wrong.

Both dependencies are lazy. A program that only lays out, or that brings its
own renderer, fetches neither.

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

Ported and tested:

- Text: styling, measuring through a `Measurer`, word wrapping, hard newlines, per-line alignment
- Sizing: fit, grow with weights, fixed, percent, ratio, with minima and maxima
- `contain` and `cover`, holding a box to an aspect ratio inside its slot
- Direction, padding, gaps, and alignment on both axes
- The element tree, and a stable number per element for state to hang off
- Rectangles, corner radii, borders, and the command list they come out as
- Clipping and scrolling, with the position remembered between frames
- Hit testing, hover, press and focus, with capture and clip-aware picking
- An optional renderer over Fluxion RHI: one instanced draw, an SDF for the shapes, a glyph atlas for the text

Not yet, in the order it is worth doing:

| | Why it is not here |
| --- | --- |
| **Floating elements, wrapping, shaders, images** | Ply has all of these. They sit above the core rather than inside it. |
| **Accessibility, networking, audio, storage** | Deliberately out of scope. Ply's are bound to its own subsystems, and this library builds on the fluxion ones. |

A container too small for its fixed children still overflows rather than
squeezing them, which is the right answer: a silent squeeze hides the problem,
and overflow is what a scroll container is for. What *can* give way is a
paragraph, down to its longest word - see [Text](#text).

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

The layout tests are layouts with known right answers, checked against the boxes that
came out - which is the only way to test a layout engine, because an
intermediate size is not worth asserting on when the next pass is allowed to
change it. The example carries its own: that the panes tile the window with no
gaps, that the sidebar keeps its width while the content takes the rest, and
that the weighted cards come out two to one to one at every window size.

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: BSL-1.0`

[Boost Software License 1.0](LICENSE) - permissive, and short enough to read
in a minute. The one obligation is that the copyright notice travels with the
*source*; a binary built from it carries nothing.

Fluxion libraries are licensed by layer: the foundation is CC0, the engine
infrastructure this one belongs to is BSL-1.0, and what builds on top of it is
BSD. [Ply](https://github.com/TheRedDeveloper/ply-engine), which this is a
port of, is 0BSD and asks for nothing.
