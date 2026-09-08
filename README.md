# Fluxion UI

A layout engine that draws nothing. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Ui` | The frame: `open`, `close`, and the three passes that follow. |
| `layout` | What an element asks for - sizing, padding, direction, alignment. |
| `geometry` | Rectangles, and the numbers that place one. |
| `color` | A colour, and the three ways people write one down. |
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
        .child_gap = 12,
        .background_color = .hex(0x14161A),
    });
    defer ui.close();

    ui.open(.{ .width = .fixed(220), .height = .grow, .background_color = .hex(0x191C21) });
    ui.close();

    ui.open(.{ .width = .grow, .height = .grow, .corner_radius = .all(10) });
    ui.close();
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
anywhere:

```zig
ui.open(.{ .width = .grow, .height = .fixed(40), .padding = .all(12) });
```

**Grow weights** are Ply's addition over Clay, and they are worth having:

```zig
ui.open(.{ .width = .growWeighted(2) });   // twice the share of a plain .grow
```

Without them the only way to make one pane twice the width of another is to
know the container's size, which is exactly what `grow` exists to avoid.

## The API is `open` and `close`

Ply passes children as a closure. Zig has no closures, so the tree is a block
and `defer` is what guarantees the pairing:

```zig
{
    ui.open(.{ .direction = .top_to_bottom, .child_gap = 8 });
    defer ui.close();

    ui.open(.{ .height = .fixed(40) });
    ui.close();
}
```

`open` and `close` report nothing. A UI declaration is a hundred calls in a
row and `try` on every one of them would drown the thing being described, so
the first failure is kept and `end` reports it - `error.ElementLeftOpen` for a
missing `close`, and the rest in `Ui.Error`. An unbalanced tree is a
programming error, not a layout that leans.

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

- Sizing: fit, grow with weights, fixed, percent, ratio, with minima and maxima
- Direction, padding, child gaps, and alignment on both axes
- The element tree, and a stable number per element for state to hang off
- Rectangles, corner radii, borders, and the command list they come out as

Not yet, in the order it is worth doing:

| | Why it is not here |
| --- | --- |
| **Text** | Needs a font; a font needs a rasteriser, and the ecosystem has not got one. `commands.Text` exists so the seam does not change shape when `fluxion-font` arrives. This is the next milestone and it gates the two below it. |
| **The RHI backend** | The seam is settled and the layout is checked; a rounded rectangle wants an SDF fragment shader and a window, which is its own piece of work. |
| **Scroll and clipping** | `scissor_start` / `scissor_end` are in the command list already. The clip container that emits them is not. |
| **Hit testing, hover, focus** | Every element's final box is recorded - see `Ui.boxOf` - which is the half of it that had to come first. |
| **Floating elements, wrapping, shaders, images** | Ply has all of these. They sit above the core rather than inside it. |
| **Accessibility, networking, audio, storage** | Deliberately out of scope. Ply's are bound to its own subsystems, and this library builds on the fluxion ones. |

One consequence worth naming: the **shrink pass is ported and in place but not
reachable from a declaration yet**. An element can only be shrunk below its own
content when that content can reflow into a smaller box, and in Ply that means
text that wraps or a clip container that does not pass its children's minimum
upwards. Both are the next milestone. Until then a container too small
overflows, which is the right answer - a silent squeeze hides the problem, and
overflow is what a scroll container is for.

## Examples

```bash
zig build example       # an application shell, printed as draw commands
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

The tests are layouts with known right answers, checked against the boxes that
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
