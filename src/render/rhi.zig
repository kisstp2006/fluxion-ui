// SPDX-License-Identifier: BSD-2-Clause

//! A renderer: `[]const RenderCommand` in, pixels out, through
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi).
//!
//! **One instanced draw for the whole frame.** Every rectangle, every border
//! and every glyph is the same unit quad under a different set of per-instance
//! numbers, and the fragment shader decides what it is looking at. A window
//! full of interface is one draw call, and adding a thousand more boxes to it
//! is still one.
//!
//! That works because the three things a UI draws are the same thing:
//!
//!   * A **rectangle** is a rounded box, filled.
//!   * A **border** is a rounded box with a smaller rounded box cut out of it.
//!   * A **glyph** is a rectangle whose alpha comes from the atlas.
//!
//! So there is one pipeline, one shader, one texture and one buffer, and the
//! only thing that breaks a batch is a scissor rectangle - which a UI changes
//! a handful of times a frame, not a thousand.
//!
//! ```zig
//! var renderer: Renderer = try .init(gpa, &device, &face);
//! defer renderer.deinit();
//!
//! try renderer.draw(.{ .surface = surface }, .init(1280, 720), try ui.end(), .black);
//! try device.present(surface);
//! ```
//!
//! Nothing here is required. The seam is `commands.RenderCommand`, and a
//! program with its own renderer ignores this file entirely - see the README.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const font = @import("fluxion_font");
const ui = @import("fluxion_ui");
// Named with a suffix because `shader` below is the handle the device gives
// back, and one of the two had to give way.
const shader_mod = @import("fluxion_shader");

const Atlas = @import("Atlas.zig");

pub const Error = rhi.types.Error || Atlas.Error || shader_mod.Error;

/// One quad's worth of per-instance data.
///
/// `extern` because it goes into a vertex buffer with a `memcpy` and the
/// attribute offsets below are byte offsets into exactly this.
pub const Instance = extern struct {
    /// Where it goes, in pixels from the top left.
    rect: [4]f32,
    color: [4]f32,
    /// Top-left, top-right, bottom-right, bottom-left.
    radii: [4]f32,
    /// The corners of the glyph in the atlas. All zero for anything that is
    /// not text.
    uv: [4]f32,
    /// Where the quad ends up, if something turned it: the two axes of the
    /// motion, as (x.x, x.y, y.x, y.y). The identity for almost everything.
    ///
    /// Only the *position* goes through it. The distance field is still
    /// measured in the box's own frame, which is why a turned rounded corner
    /// is still a rounded corner and its edge is still one pixel wide - a
    /// rigid motion cannot stretch either.
    motion: [4]f32,

    /// How thick the border is, in pixels. Zero fills the whole box.
    border: f32,
    /// What the fragment shader is looking at: `Kind`, as a float because
    /// that is what a vertex attribute is. A number rather than three
    /// pipelines, because three pipelines would be three draw calls and a
    /// state change between every label and the box behind it.
    textured: f32,
    /// Where the origin lands after `motion`. Beside `border` and `textured`
    /// so the three of them are one `float4` attribute rather than two.
    origin: [2]f32,

    /// The three things one quad can be.
    pub const Kind = struct {
        /// A rectangle or a border: the rounded-box distance field, filled.
        pub const shape: f32 = 0;
        /// A glyph: one channel of coverage out of the atlas, in `color`.
        pub const glyph: f32 = 1;
        /// A picture: all four channels of a texture, tinted by `color` and
        /// cut to the same rounded box a rectangle would be.
        pub const image: f32 = 2;
    };
};

/// What a frame tells the shader. Sixteen bytes, `std140`.
const Frame = extern struct {
    viewport: [4]f32,
};

/// A run of instances drawn under one scissor rectangle, with one texture.
const Batch = struct {
    first: u32,
    count: u32,
    scissor: ?rhi.types.Rect,
    /// What to bind at slot zero, or null for the glyph atlas.
    ///
    /// The second thing that breaks a batch, after the scissor. A shape needs
    /// no texture and joins whichever batch it lands in; text needs the
    /// atlas; a picture needs its own. Interfaces that draw their icons from
    /// one sheet stay one draw call, which is the whole reason the source
    /// rectangle exists.
    texture: ?rhi.types.Texture = null,
};

const quad_vertices = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,
    face: *const font.Font,

    atlas: Atlas,
    atlas_texture: rhi.types.Texture,
    /// What an image command's number means. Borrowed, and must outlive the
    /// frame it is drawn in. See `setTextures`.
    textures: []const rhi.types.Texture = &.{},

    /// What the animated text styles are animated against. See `setTime`.
    time: f64 = 0,
    /// When each named reveal started, by the hash of its name.
    ///
    /// A `type` or `fade` runs from the first frame it is seen on, so it has
    /// to be remembered somewhere - and two runs sharing an `id` share a
    /// start, which is what the name is for. Never swept: the names are
    /// written in the program's own strings, so there is a fixed number of
    /// them however long it runs.
    clocks: std.AutoHashMapUnmanaged(u32, f64) = .empty,
    sampler: rhi.types.Sampler,

    shader: rhi.types.Shader,
    pipeline: rhi.types.Pipeline,
    quad: rhi.types.Buffer,
    instance_buffer: rhi.types.Buffer,
    instance_capacity: u32,
    frame_buffer: rhi.types.Buffer,

    instances: std.ArrayList(Instance),
    batches: std.ArrayList(Batch),
    /// The scissor rectangles currently open, innermost last.
    clips: std.ArrayList(rhi.types.Rect),

    /// How many instances the buffer starts with. It grows when a frame needs
    /// more; it never shrinks, because a UI that once drew a thousand boxes
    /// will draw them again.
    const initial_instances: u32 = 1024;

    /// How big the glyph atlas is. One texture, and 1024 square holds a few
    /// alphabets at the sizes an interface uses.
    const atlas_size: u32 = 1024;

    pub fn init(gpa: Allocator, device: *rhi.Device, face: *const font.Font) Error!Renderer {
        var atlas: Atlas = try .init(gpa, atlas_size, atlas_size);
        errdefer atlas.deinit();

        const atlas_texture = try device.createTexture(.{
            .width = atlas_size,
            .height = atlas_size,
            // One byte a pixel: a glyph is coverage, not colour, and the
            // colour comes from the instance.
            .format = .r8_unorm,
            .label = "fluxion-ui glyphs",
        });
        errdefer device.destroyTexture(atlas_texture);

        const sampler = try device.createSampler(.linear);
        errdefer device.destroySampler(sampler);

        // One source, every backend's language: GLSL for OpenGL, GLSL ES
        // for WebGL and HLSL for Direct3D. Compiling it here rather than
        // shipping hand-written translations is what stops the same shader
        // existing three times in this repository and drifting apart.
        var log: std.Io.Writer.Allocating = .init(gpa);
        defer log.deinit();

        var module = shader_mod.compile(gpa, shader_source, &log.writer) catch |err| {
            // Logged rather than swallowed: the alternative to a message
            // with a line and a caret under it is a blank window, and a
            // blank window is the hardest thing in graphics to look at.
            // Through `std.log` rather than `std.debug.print`, which has
            // nowhere to print in a browser and does not compile for one;
            // a program there points `std.log` at the console.
            std.log.err("fluxion-ui shader:\n{s}", .{log.written()});
            return err;
        };
        defer module.deinit();

        const shader = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .label = "fluxion-ui",
        });
        errdefer device.destroyShader(shader);

        const pipeline = try device.createPipeline(.{
            .shader = shader,
            .buffers = &.{
                .{ .stride = @sizeOf(f32) * 2 },
                .{ .stride = @sizeOf(Instance), .step = .instance },
            },
            .attributes = &.{
                .{ .location = 0, .format = .float2, .offset = 0, .buffer = 0 },
                .{ .location = 1, .format = .float4, .offset = @offsetOf(Instance, "rect"), .buffer = 1 },
                .{ .location = 2, .format = .float4, .offset = @offsetOf(Instance, "color"), .buffer = 1 },
                .{ .location = 3, .format = .float4, .offset = @offsetOf(Instance, "radii"), .buffer = 1 },
                .{ .location = 4, .format = .float4, .offset = @offsetOf(Instance, "uv"), .buffer = 1 },
                .{ .location = 5, .format = .float4, .offset = @offsetOf(Instance, "border"), .buffer = 1 },
                .{ .location = 6, .format = .float4, .offset = @offsetOf(Instance, "motion"), .buffer = 1 },
            },
            .topology = .triangle_strip,
            // Straight alpha, because that is what a colour written as
            // `0xRRGGBB` with an alpha beside it means.
            .blend = .alpha,
            .uniform_blocks = &.{"Frame"},
            .textures = &.{"u_atlas"},
            .label = "fluxion-ui",
        });
        errdefer device.destroyPipeline(pipeline);

        const quad = try device.createBuffer(.{
            .kind = .vertex,
            .size = @sizeOf(@TypeOf(quad_vertices)),
            .data = std.mem.asBytes(&quad_vertices),
            .label = "fluxion-ui quad",
        });
        errdefer device.destroyBuffer(quad);

        const instance_buffer = try device.createBuffer(.{
            .kind = .vertex,
            .size = @sizeOf(Instance) * initial_instances,
            .dynamic = true,
            .label = "fluxion-ui instances",
        });
        errdefer device.destroyBuffer(instance_buffer);

        const frame_buffer = try device.createBuffer(.{
            .kind = .uniform,
            .size = @sizeOf(Frame),
            .dynamic = true,
            .label = "fluxion-ui frame",
        });
        errdefer device.destroyBuffer(frame_buffer);

        return .{
            .gpa = gpa,
            .device = device,
            .face = face,
            .atlas = atlas,
            .atlas_texture = atlas_texture,
            .sampler = sampler,
            .shader = shader,
            .pipeline = pipeline,
            .quad = quad,
            .instance_buffer = instance_buffer,
            .instance_capacity = initial_instances,
            .frame_buffer = frame_buffer,
            .instances = .empty,
            .batches = .empty,
            .clips = .empty,
        };
    }

    /// Say what an image command's texture number means.
    ///
    /// A command carries a number because the layout half has never heard of
    /// a GPU; this is where the number becomes a texture. The slice is
    /// borrowed and has to outlive the frames drawn from it. A number with no
    /// texture behind it draws the background and nothing else, which is a
    /// missing picture rather than a crash.
    pub fn setTextures(self: *Renderer, textures: []const rhi.types.Texture) void {
        self.textures = textures;
    }

    /// Say what time it is, in seconds.
    ///
    /// Only the animated markup styles read it, and a program that uses none
    /// of them need never call this. Any clock will do as long as it goes
    /// forwards: seconds since the program started is the usual one.
    pub fn setTime(self: *Renderer, seconds: f64) void {
        self.time = seconds;
    }

    pub fn deinit(self: *Renderer) void {
        self.device.destroyBuffer(self.frame_buffer);
        self.device.destroyBuffer(self.instance_buffer);
        self.device.destroyBuffer(self.quad);
        self.device.destroyPipeline(self.pipeline);
        self.device.destroyShader(self.shader);
        self.device.destroySampler(self.sampler);
        self.clocks.deinit(self.gpa);
        self.device.destroyTexture(self.atlas_texture);
        self.atlas.deinit();
        self.instances.deinit(self.gpa);
        self.batches.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.* = undefined;
    }

    /// Draw a frame's commands into `target`.
    ///
    /// `size` is the target in pixels, and is what the shader turns pixel
    /// coordinates into clip space with - so it must be the size the layout
    /// was given, or everything lands in the wrong place at the right shape.
    ///
    /// A `RenderTarget` rather than a `Surface`, so the same renderer draws
    /// into a texture: that is what a screenshot, a cached panel and this
    /// library's own GPU test all are. **Presenting is the caller's**, because
    /// only a surface can be presented and only the caller knows whether it
    /// wants to.
    pub fn draw(
        self: *Renderer,
        target: rhi.types.RenderTarget,
        size: ui.Dimensions,
        commands: []const ui.RenderCommand,
        /// What to fill the target with first, or **null to draw on top of
        /// what is already there**.
        ///
        /// An interface is not always the first thing in a target. A game
        /// draws its scene and then its interface into one surface, and a
        /// pass that cleared would wipe the scene - so the third layer could
        /// not exist at all. A `Color` still coerces to this on its own, so
        /// nothing that only ever draws an interface has to say anything.
        clear: ?ui.Color,
    ) Error!void {
        try self.build(commands, size);

        if (self.atlas.dirty) {
            try self.device.updateTexture(self.atlas_texture, self.atlas.pixels, self.atlas.width);
            self.atlas.markClean();
        }

        if (self.instances.items.len > 0) {
            try self.reserve(@intCast(self.instances.items.len));
            try self.device.updateBuffer(
                self.instance_buffer,
                0,
                std.mem.sliceAsBytes(self.instances.items),
            );
        }

        const frame: Frame = .{ .viewport = .{ size.width, size.height, 0, 0 } };
        try self.device.updateBuffer(self.frame_buffer, 0, std.mem.asBytes(&frame));

        const list = self.device.begin();
        try list.beginPass(.{ .color = .{
            .target = target,
            .load = if (clear == null) .load else .clear,
            .clear_color = if (clear) |colour| colour.array() else .{ 0, 0, 0, 1 },
        } });
        try list.setViewport(.{ .width = size.width, .height = size.height });
        try list.setPipeline(self.pipeline);
        try list.setVertexBuffer(0, self.quad, 0);
        try list.setUniformBuffer(0, self.frame_buffer);
        try list.setTexture(0, self.atlas_texture, self.sampler);

        for (self.batches.items) |batch| {
            if (batch.count == 0) continue;
            try list.setScissor(batch.scissor);
            try list.setTexture(0, batch.texture orelse self.atlas_texture, self.sampler);
            // A draw has no first-instance field, so a batch starts where its
            // buffer binding says it does. The offset is in bytes, and this
            // is the whole of what makes several scissor regions one buffer.
            try list.setVertexBuffer(1, self.instance_buffer, batch.first * @sizeOf(Instance));
            try list.draw(.{ .vertex_count = 4, .instance_count = batch.count });
        }

        try list.setScissor(null);
        try list.endPass();
        try self.device.submit();
    }

    /// Turn the command list into instances and batches.
    ///
    /// Separated from `draw` so a test can look at what would be drawn
    /// without a device that draws anything - which is what the tests at the
    /// bottom of this file do.
    pub fn build(self: *Renderer, commands: []const ui.RenderCommand, size: ui.Dimensions) Error!void {
        self.instances.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();

        var batch_start: u32 = 0;
        var scissor: ?rhi.types.Rect = null;
        // What this batch has already committed to, or null while it is still
        // only shapes and could go either way.
        var bound: ?rhi.types.Texture = null;

        for (commands) |command| {
            const turn = turnOf(command.transform);
            switch (command.config) {
                .scissor_start => {
                    try self.closeBatch(&batch_start, scissor, bound);
                    const box = command.bounding_box;
                    const wanted = intersect(scissor, box, size);
                    try self.clips.append(self.gpa, wanted);
                    scissor = wanted;
                },
                .scissor_end => {
                    try self.closeBatch(&batch_start, scissor, bound);
                    _ = self.clips.pop();
                    scissor = if (self.clips.items.len > 0)
                        self.clips.items[self.clips.items.len - 1]
                    else
                        null;
                },
                .rectangle => |fill| try self.instances.append(self.gpa, .{
                    .rect = boxArray(command.bounding_box),
                    .color = fill.color.array(),
                    .radii = fill.corner_radius.array(),
                    .uv = @splat(0),
                    .motion = turn.motion,
                    .border = 0,
                    .textured = Instance.Kind.shape,
                    .origin = turn.origin,
                }),
                .border => |line| try self.instances.append(self.gpa, .{
                    .rect = boxArray(command.bounding_box),
                    .color = line.color.array(),
                    .radii = line.corner_radius.array(),
                    .uv = @splat(0),
                    // One width for all four sides. Four different ones would
                    // need four quads, and no interface has ever asked.
                    .motion = turn.motion,
                    .border = @floatFromInt(@max(
                        @max(line.width.left, line.width.right),
                        @max(line.width.top, line.width.bottom),
                    )),
                    .textured = Instance.Kind.shape,
                    .origin = turn.origin,
                }),
                .text => |run| {
                    if (bound != null and !std.meta.eql(bound.?, self.atlas_texture)) {
                        try self.closeBatch(&batch_start, scissor, bound);
                    }
                    bound = self.atlas_texture;
                    try self.addText(command, run);
                },
                .image => |picture| {
                    // The fill goes down first, in its own instance, because
                    // one quad cannot be both a colour and a picture - and
                    // this way it is the same rectangle path as everything
                    // else rather than a second one in the shader.
                    if (!picture.background_color.invisible()) {
                        try self.instances.append(self.gpa, .{
                            .rect = boxArray(command.bounding_box),
                            .color = picture.background_color.array(),
                            .radii = picture.corner_radius.array(),
                            .uv = @splat(0),
                            .motion = turn.motion,
                            .border = 0,
                            .textured = Instance.Kind.shape,
                            .origin = turn.origin,
                        });
                    }

                    if (picture.texture >= self.textures.len) continue;
                    const wanted = self.textures[picture.texture];
                    if (bound != null and !std.meta.eql(bound.?, wanted)) {
                        try self.closeBatch(&batch_start, scissor, bound);
                    }
                    bound = wanted;

                    try self.instances.append(self.gpa, .{
                        .rect = boxArray(command.bounding_box),
                        .color = picture.tint.array(),
                        .radii = picture.corner_radius.array(),
                        .uv = .{
                            picture.source.x,
                            picture.source.y,
                            picture.source.right(),
                            picture.source.bottom(),
                        },
                        .motion = turn.motion,
                        .border = 0,
                        .textured = Instance.Kind.image,
                        .origin = turn.origin,
                    });
                },
                .none => {},
            }
        }

        try self.closeBatch(&batch_start, scissor, bound);
    }

    /// The two instance fields a command's transform becomes.
    fn turnOf(transform: ui.geometry.Transform) struct { motion: [4]f32, origin: [2]f32 } {
        return .{
            .motion = .{
                transform.x_axis.x,
                transform.x_axis.y,
                transform.y_axis.x,
                transform.y_axis.y,
            },
            .origin = .{ transform.origin.x, transform.origin.y },
        };
    }

    /// What the effects do to one glyph.
    const Moved = struct {
        /// Added to where the glyph would have been, in pixels.
        offset: ui.geometry.Vec2 = .{ .x = 0, .y = 0 },
        scale: ui.geometry.Vec2 = .{ .x = 1, .y = 1 },
        /// In radians, about the middle of the glyph.
        rotate: f32 = 0,
        /// Multiplied into the alpha.
        opacity: f32 = 1,
        color: ?ui.Color = null,
        hidden: bool = false,
    };

    /// Work out what one glyph of one frame looks like.
    ///
    /// Ply's arithmetic, effect by effect, with its defaults. `index` is how
    /// many characters into the whole run this glyph is, which is what makes
    /// a wave travel along a word instead of every letter moving together.
    fn moveGlyph(
        self: *Renderer,
        effects: []const ui.markup.Effect,
        index: f32,
        em: f32,
    ) Moved {
        var moved: Moved = .{};

        for (effects) |effect| switch (effect) {
            .wave => |wave| {
                // A displacement along a direction, which is straight down
                // until `r` says otherwise.
                const distance = wave.cycle.at(self.time, index) * wave.cycle.amplitude * em;
                const along = wave.direction * std.math.pi / 180.0;
                moved.offset.x += -distance * @sin(along);
                moved.offset.y += distance * @cos(along);
            },
            .pulse => |cycle| {
                const size = 1 + cycle.at(self.time, index) * cycle.amplitude;
                moved.scale.x *= size;
                moved.scale.y *= size;
            },
            .swing => |cycle| {
                // Ply's amplitude here is in degrees, and its wave is a sine
                // rather than a cosine - a swing starts upright.
                const width = if (cycle.width == 0) 1 else cycle.width;
                const turns = cycle.frequency * @as(f32, @floatCast(self.time)) +
                    index / width + cycle.phase;
                moved.rotate += @sin(2 * std.math.pi * turns) *
                    cycle.amplitude * std.math.pi / 180.0;
            },
            .jitter => |jitter| {
                // Twenty steps a second, so it shakes rather than shimmers,
                // and the same nonsense-from-a-sine Ply uses for the numbers.
                const seed = @floor(@as(f32, @floatCast(self.time)) * 20) + index * 13.37;
                const x = fract(@sin(seed) * 43758.5453);
                const y = fract(@cos(seed + 7.1) * 23421.632);
                const shake_x = (x - 0.5) * 2 * jitter.radius.x * em;
                const shake_y = (y - 0.5) * 2 * jitter.radius.y * em;
                const along = jitter.rotation * std.math.pi / 180.0;
                moved.offset.x += shake_x * @cos(along) - shake_y * @sin(along);
                moved.offset.y += shake_x * @sin(along) + shake_y * @cos(along);
            },
            .transform => |fixed| {
                moved.offset.x += fixed.translate.x * em;
                moved.offset.y += fixed.translate.y * em;
                moved.scale.x *= fixed.scale.x;
                moved.scale.y *= fixed.scale.y;
                moved.rotate += fixed.rotate * std.math.pi / 180.0;
            },
            .gradient => |gradient| {
                moved.color = gradient.sample(index - @as(f32, @floatCast(self.time)) * gradient.speed);
            },
            .reveal => |reveal| {
                const started = self.clocks.get(reveal.clock) orelse blk: {
                    self.clocks.put(self.gpa, reveal.clock, self.time) catch {};
                    break :blk self.time;
                };
                const elapsed = @max(0, @as(f32, @floatCast(self.time - started)) - reveal.delay);
                const reached = elapsed * reveal.speed;

                switch (reveal.kind) {
                    // No edge: a letter is either there or it is not.
                    .type => {
                        const arrived = index < reached;
                        if (arrived == reveal.out) moved.hidden = true;
                    },
                    .fade, .scale => {
                        const trail = if (reveal.trail == 0) 1 else reveal.trail;
                        const progress = std.math.clamp((reached - index) / trail, 0, 1);
                        const amount = if (reveal.out) 1 - progress else progress;
                        if (reveal.kind == .fade) {
                            moved.opacity *= amount;
                        } else {
                            moved.scale.x *= amount;
                            moved.scale.y *= amount;
                        }
                    },
                }
            },
        };

        return moved;
    }

    /// The part after the point, which is what Ply's `fract` is.
    fn fract(value: f32) f32 {
        return value - @floor(value);
    }

    /// One instance per glyph of a line.
    fn addText(self: *Renderer, command: ui.RenderCommand, run: ui.commands.Text) Error!void {
        const turn = turnOf(command.transform);
        const size: u16 = run.font_size;
        const scale = self.face.scaleFor(@floatFromInt(size));

        // The command's box is the line; the baseline is one ascent down it.
        const baseline = command.bounding_box.y + self.face.at(@floatFromInt(size)).ascent();
        var pen = command.bounding_box.x;
        var previous: ?u16 = null;

        const em: f32 = @floatFromInt(size);
        var at: u32 = run.first;

        var letters = (std.unicode.Utf8View.init(run.text) catch return).iterator();
        while (letters.nextCodepoint()) |codepoint| {
            const index = self.face.glyphFor(codepoint);
            if (previous) |left| {
                pen += @as(f32, @floatFromInt(self.face.kern(left, index) catch 0)) * scale;
            }
            previous = index;
            defer at += 1;

            const entry = try self.atlas.glyph(self.face, index, size);
            if (entry.isBlank()) {
                pen += entry.advance;
                continue;
            }
            defer pen += entry.advance;

            // The pen does not care what the effects do: a wave moves where a
            // letter is drawn and not where the next one starts, or the word
            // would stretch and squash as it went.
            const box: [4]f32 = .{
                pen + @as(f32, @floatFromInt(entry.left)),
                baseline - @as(f32, @floatFromInt(entry.top)),
                @floatFromInt(entry.width),
                @floatFromInt(entry.height),
            };

            if (run.effects.len == 0) {
                try self.instances.append(self.gpa, .{
                    .rect = box,
                    .color = run.color.array(),
                    .radii = @splat(0),
                    .uv = .{ entry.u0, entry.v0, entry.u1, entry.v1 },
                    .motion = turn.motion,
                    .border = 0,
                    .textured = Instance.Kind.glyph,
                    .origin = turn.origin,
                });
                continue;
            }

            const moved = self.moveGlyph(run.effects, @floatFromInt(at), em);
            if (moved.hidden) continue;

            var colour = moved.color orelse run.color;
            colour.a = std.math.clamp(colour.a * moved.opacity, 0, 1);
            if (colour.invisible()) continue;

            // A glyph turns and grows about its own middle and is then
            // moved, and whatever the element was turned by goes on top -
            // which is how a waving word inside a tilted badge stays in the
            // badge. This one is not a rigid motion, because a pulse scales
            // it; nothing ever asks for it back, which is the only thing
            // rigidity buys.
            const middle_x = box[0] + box[2] / 2;
            const middle_y = box[1] + box[3] / 2;
            const cos = @cos(moved.rotate);
            const sin = @sin(moved.rotate);
            const m00 = cos * moved.scale.x;
            const m10 = sin * moved.scale.x;
            const m01 = -sin * moved.scale.y;
            const m11 = cos * moved.scale.y;
            const glyph: ui.geometry.Transform = .{
                .x_axis = .{ .x = m00, .y = m10 },
                .y_axis = .{ .x = m01, .y = m11 },
                .origin = .{
                    .x = middle_x + moved.offset.x - (m00 * middle_x + m01 * middle_y),
                    .y = middle_y + moved.offset.y - (m10 * middle_x + m11 * middle_y),
                },
            };
            const both = turnOf(glyph.then(command.transform));

            try self.instances.append(self.gpa, .{
                .rect = box,
                .color = colour.array(),
                .radii = @splat(0),
                .uv = .{ entry.u0, entry.v0, entry.u1, entry.v1 },
                .motion = both.motion,
                .border = 0,
                .textured = Instance.Kind.glyph,
                .origin = both.origin,
            });
        }
    }

    fn closeBatch(
        self: *Renderer,
        first: *u32,
        scissor: ?rhi.types.Rect,
        texture: ?rhi.types.Texture,
    ) Allocator.Error!void {
        const now: u32 = @intCast(self.instances.items.len);
        if (now > first.*) {
            try self.batches.append(self.gpa, .{
                .first = first.*,
                .count = now - first.*,
                .scissor = scissor,
                .texture = texture,
            });
        }
        first.* = now;
    }

    /// Grow the instance buffer if this frame needs more room than the last.
    fn reserve(self: *Renderer, wanted: u32) Error!void {
        if (wanted <= self.instance_capacity) return;

        var capacity = self.instance_capacity;
        while (capacity < wanted) capacity *= 2;

        const bigger = try self.device.createBuffer(.{
            .kind = .vertex,
            .size = @sizeOf(Instance) * capacity,
            .dynamic = true,
            .label = "fluxion-ui instances",
        });
        self.device.destroyBuffer(self.instance_buffer);
        self.instance_buffer = bigger;
        self.instance_capacity = capacity;
    }
};

inline fn boxArray(box: ui.BoundingBox) [4]f32 {
    return .{ box.x, box.y, box.width, box.height };
}

/// A scissor rectangle in whole pixels, inside whatever is already clipped.
///
/// Nested clips have to intersect rather than replace, or an inner one would
/// let through what its parent was hiding. Clamped to the surface, because a
/// backend given a rectangle off the edge is entitled to refuse it.
fn intersect(current: ?rhi.types.Rect, box: ui.BoundingBox, size: ui.Dimensions) rhi.types.Rect {
    var x0 = @max(0, @floor(box.x));
    var y0 = @max(0, @floor(box.y));
    var x1 = @min(size.width, @ceil(box.right()));
    var y1 = @min(size.height, @ceil(box.bottom()));

    if (current) |outer| {
        x0 = @max(x0, @as(f32, @floatFromInt(outer.x)));
        y0 = @max(y0, @as(f32, @floatFromInt(outer.y)));
        x1 = @min(x1, @as(f32, @floatFromInt(outer.x)) + @as(f32, @floatFromInt(outer.width)));
        y1 = @min(y1, @as(f32, @floatFromInt(outer.y)) + @as(f32, @floatFromInt(outer.height)));
    }

    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .width = @intFromFloat(@max(0, x1 - x0)),
        .height = @intFromFloat(@max(0, y1 - y0)),
    };
}

// -------------------------------------------------------------------------
// Shaders
// -------------------------------------------------------------------------

/// The one shader, in the one language, that every backend is compiled from.
///
/// What it draws is a signed distance to a rounded box - negative inside,
/// positive outside, and the value in pixels, so `0.5 - d` clamped to zero
/// and one is a one-pixel antialiased edge that needs no multisampling and no
/// extra geometry. Iñigo Quílez's, with the four corners split out.
const shader_source = @embedFile("shaders/ui.fxs");

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------
//
// Against the `none` backend, which accepts every call and draws nothing. It
// is exactly what a renderer's tests want: the instances and the scissor
// batches are the whole of what this file decides, and they can be looked at
// on a machine with no GPU, no window and no driver.

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

/// A device, a font and a renderer, or a skip.
const Fixture = struct {
    bytes: []u8,
    device: rhi.Device,
    face: font.Font,
    renderer: Renderer,

    fn init(gpa: Allocator) !?*Fixture {
        const bytes = try systemFont(gpa) orelse return null;
        errdefer gpa.free(bytes);

        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        self.bytes = bytes;
        self.device = try .init(gpa, .{ .backend = .none });
        self.face = try .init(bytes);
        self.renderer = try .init(gpa, &self.device, &self.face);
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.renderer.deinit();
        self.device.deinit();
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

const page: ui.Dimensions = .init(800, 600);

test "a rectangle becomes one instance where the layout put it" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{
        .{
            .bounding_box = .init(10, 20, 100, 50),
            .config = .{ .rectangle = .{
                .color = .hex(0xFF8800),
                .corner_radius = .all(8),
            } },
        },
    }, page);

    const instances = fixture.renderer.instances.items;
    try testing.expectEqual(1, instances.len);
    try testing.expectEqual([4]f32{ 10, 20, 100, 50 }, instances[0].rect);
    try testing.expectEqual([4]f32{ 8, 8, 8, 8 }, instances[0].radii);
    try testing.expectEqual(@as(f32, 0), instances[0].border);
    try testing.expectEqual(@as(f32, 0), instances[0].textured);

    // One batch, no scissor.
    try testing.expectEqual(1, fixture.renderer.batches.items.len);
    try testing.expectEqual(null, fixture.renderer.batches.items[0].scissor);
}

test "a border becomes the same quad with a width on it" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{
        .{
            .bounding_box = .init(0, 0, 100, 100),
            .config = .{ .border = .{
                .color = .white,
                .width = .all(3),
                .corner_radius = .all(6),
            } },
        },
    }, page);

    const instances = fixture.renderer.instances.items;
    try testing.expectEqual(1, instances.len);
    // The width is what tells the shader to cut the middle out, which is the
    // whole difference between a border and a filled box.
    try testing.expectEqual(@as(f32, 3), instances[0].border);
    try testing.expectEqual(@as(f32, 0), instances[0].textured);
}

test "text becomes one instance per glyph, advancing along the line" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{
        .{
            .bounding_box = .init(20, 30, 200, 20),
            .config = .{ .text = .{
                .text = "Hi",
                .color = .white,
                .font_size = 16,
            } },
        },
    }, page);

    const instances = fixture.renderer.instances.items;
    // Two letters, both with ink.
    try testing.expectEqual(2, instances.len);
    for (instances) |instance| {
        try testing.expectEqual(@as(f32, 1), instance.textured);
        // A glyph has a real patch of the atlas behind it.
        try testing.expect(instance.uv[2] > instance.uv[0]);
        try testing.expect(instance.uv[3] > instance.uv[1]);
    }

    // The second letter is to the right of the first, which is the pen
    // advancing - and the thing that would be wrong if the atlas entry's
    // advance were being ignored.
    try testing.expect(instances[1].rect[0] > instances[0].rect[0]);

    // Both are on the same line, near the box the layout gave them.
    for (instances) |instance| {
        try testing.expect(instance.rect[1] >= 30 - 1);
        try testing.expect(instance.rect[1] < 30 + 20);
    }

    // And the glyphs went into the atlas, so the texture needs uploading.
    try testing.expect(fixture.renderer.atlas.dirty);
    try testing.expectEqual(2, fixture.renderer.atlas.count());
}

test "a space moves the pen and adds no instance" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{
        .{
            .bounding_box = .init(0, 0, 200, 20),
            .config = .{ .text = .{ .text = "a b", .color = .white, .font_size = 16 } },
        },
    }, page);

    // Two letters, not three: a blank glyph is not a draw call.
    const instances = fixture.renderer.instances.items;
    try testing.expectEqual(2, instances.len);
    // But the space was paid for, so the `b` is further along than it would
    // be if the space had been skipped entirely.
    try testing.expect(instances[1].rect[0] > instances[0].rect[0] + 8);
}

test "a scissor pair splits the frame into batches" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const white: ui.commands.Rectangle = .{ .color = .white };

    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .rectangle = white } },
        .{ .bounding_box = .init(100, 100, 200, 200), .config = .scissor_start },
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .rectangle = white } },
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .rectangle = white } },
        .{ .bounding_box = .init(0, 0, 0, 0), .config = .scissor_end },
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .rectangle = white } },
    }, page);

    try testing.expectEqual(4, fixture.renderer.instances.items.len);

    // Three batches: before the clip, inside it, and after.
    const batches = fixture.renderer.batches.items;
    try testing.expectEqual(3, batches.len);

    try testing.expectEqual(null, batches[0].scissor);
    try testing.expectEqual(1, batches[0].count);

    try testing.expectEqual(2, batches[1].count);
    try testing.expectEqual(1, batches[1].first);
    const clip = batches[1].scissor.?;
    try testing.expectEqual(100, clip.x);
    try testing.expectEqual(200, clip.width);

    // And the clip is let go afterwards.
    try testing.expectEqual(null, batches[2].scissor);
    try testing.expectEqual(3, batches[2].first);
}

test "a clip inside a clip is the part they share" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(100, 100, 200, 200), .config = .scissor_start },
        .{ .bounding_box = .init(50, 150, 200, 200), .config = .scissor_start },
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .rectangle = .{ .color = .white } } },
        .{ .bounding_box = .zero, .config = .scissor_end },
        .{ .bounding_box = .zero, .config = .scissor_end },
    }, page);

    const batches = fixture.renderer.batches.items;
    try testing.expectEqual(1, batches.len);

    // The overlap of (100..300, 100..300) and (50..250, 150..350) is
    // (100..250, 150..300). An inner clip that replaced its parent instead
    // of intersecting it would let through what the parent was hiding.
    const clip = batches[0].scissor.?;
    try testing.expectEqual(100, clip.x);
    try testing.expectEqual(150, clip.y);
    try testing.expectEqual(150, clip.width);
    try testing.expectEqual(150, clip.height);
}

test "a clip is held inside the surface" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{
        // Half off the left and bottom of an 800 by 600 surface.
        .{ .bounding_box = .init(-100, 500, 400, 400), .config = .scissor_start },
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .rectangle = .{ .color = .white } } },
        .{ .bounding_box = .zero, .config = .scissor_end },
    }, page);

    const clip = fixture.renderer.batches.items[0].scissor.?;
    // A backend handed a rectangle off the edge is entitled to refuse it.
    try testing.expectEqual(0, clip.x);
    try testing.expectEqual(500, clip.y);
    try testing.expectEqual(300, clip.width);
    try testing.expectEqual(100, clip.height);
}

test "an empty frame draws nothing at all" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    try fixture.renderer.build(&.{}, page);
    try testing.expectEqual(0, fixture.renderer.instances.items.len);
    try testing.expectEqual(0, fixture.renderer.batches.items.len);
}

test "a frame is built from scratch each time" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const one: ui.RenderCommand = .{
        .bounding_box = .init(0, 0, 10, 10),
        .config = .{ .rectangle = .{ .color = .white } },
    };

    for (0..3) |_| {
        try fixture.renderer.build(&.{ one, one }, page);
        // Two, not two more than last time.
        try testing.expectEqual(2, fixture.renderer.instances.items.len);
        try testing.expectEqual(1, fixture.renderer.batches.items.len);
    }
}

test "the whole thing runs end to end against a device that draws nothing" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const surface = try fixture.device.createSurface(.{ .width = 800, .height = 600 });
    defer fixture.device.destroySurface(surface);

    var layout: ui.Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(.monospace(0.5, 1.0));

    layout.begin(.{ .size = page });
    {
        layout.open(.{
            .width = .grow,
            .height = .grow,
            .padding = .all(20),
            .gap = 10,
            .direction = .top_to_bottom,
            .background_color = .hex(0x14161A),
        });
        defer layout.close();

        layout.text("Fluxion UI", .{ .font_size = 20, .color = .white });
        layout.empty(.{
            .width = .grow,
            .height = .fixed(40),
            .corner_radius = .all(8),
            .background_color = .hex(0x232830),
            .border = .all(.hex(0x2E343D), 1),
        });
    }
    const commands = try layout.end();

    // A real frame, through the whole renderer: instances built, buffers
    // written, a pass recorded and submitted. The `none` backend validates
    // every call and draws none of them, which is the point.
    try fixture.renderer.draw(.{ .surface = surface }, page, commands, .hex(0x000000));

    // The background, the panel, its border, and a glyph for every letter of
    // the title that has ink.
    try testing.expect(fixture.renderer.instances.items.len > 5);
    try testing.expect(fixture.renderer.atlas.count() > 0);
}

test "the WebGL backend is handed the shader in its own language" {
    // Off wasm, fluxion-rhi's WebGL backend runs against fluxion-webgl's
    // stub, which compiles anything and draws nothing - so this is not about
    // the picture. It is about the one thing that decides between a picture
    // and a blank canvas before a browser is ever opened: WebGL reads GLSL
    // ES and nothing else, and a renderer that hands over only GLSL and HLSL
    // is refused at `init`.
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .webgl });
    defer device.deinit();
    try testing.expectEqual(rhi.Backend.webgl, device.backendTag());

    // The canvas, which the stub says is 800 by 600 - the same as `page`.
    const surface = try device.createSurface(.{});
    defer device.destroySurface(surface);

    var face: font.Font = try .init(bytes);
    var renderer: Renderer = try .init(testing.allocator, &device, &face);
    defer renderer.deinit();

    var layout: ui.Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(.monospace(0.5, 1.0));

    layout.begin(.{ .size = page });
    {
        layout.open(.{ .width = .grow, .height = .grow, .padding = .all(20) });
        defer layout.close();
        layout.text("Fluxion UI", .{ .font_size = 20, .color = .white });
    }
    const commands = try layout.end();

    // A whole frame through the backend: the atlas uploaded, the buffers
    // written, the uniform block and the sampler bound by slot, and drawn.
    try renderer.draw(.{ .surface = surface }, page, commands, .black);
    try device.present(surface);
}

test "a frame with more boxes than the buffer holds grows it" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const before = fixture.renderer.instance_capacity;

    var many: std.ArrayList(ui.RenderCommand) = .empty;
    defer many.deinit(testing.allocator);
    for (0..before + 100) |i| {
        const at: f32 = @floatFromInt(i % 700);
        try many.append(testing.allocator, .{
            .bounding_box = .init(at, at, 4, 4),
            .config = .{ .rectangle = .{ .color = .white } },
        });
    }

    const surface = try fixture.device.createSurface(.{ .width = 800, .height = 600 });
    defer fixture.device.destroySurface(surface);

    try fixture.renderer.draw(.{ .surface = surface }, page, many.items, .black);

    // It grew rather than dropping the ones that did not fit.
    try testing.expect(fixture.renderer.instance_capacity > before);
    try testing.expectEqual(before + 100, fixture.renderer.instances.items.len);
}

test "the Direct3D shaders compile and the frame reaches the pixels" {
    // The other half of the shader pair. The OpenGL one is proved by
    // `examples/window.zig`, which needs a display; this one needs no window
    // at all - a Direct3D device is made without one, and the frame goes into
    // a texture that is read straight back.
    //
    // Worth its own test because HLSL and GLSL are written side by side and
    // only one of them was ever run. A semantic that does not match, a
    // constant buffer packed differently, a `float2` where a `float4` was
    // expected: all of them produce a blank window and none of them produce
    // an error anywhere else.
    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    var device: rhi.Device = rhi.Device.init(testing.allocator, .{ .backend = .d3d11 }) catch
        return error.SkipZigTest;
    defer device.deinit();

    // Said out loud, because a test that quietly ran on another backend
    // would prove exactly nothing about the HLSL it was written for.
    try testing.expectEqual(rhi.Backend.d3d11, device.backendTag());

    const target = try device.createTexture(.{
        .width = 128,
        .height = 128,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer device.destroyTexture(target);

    var face: font.Font = try .init(bytes);
    var renderer: Renderer = try .init(testing.allocator, &device, &face);
    defer renderer.deinit();

    const size: ui.Dimensions = .init(128, 128);

    var layout: ui.Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(.monospace(0.5, 1.0));

    layout.begin(.{ .size = size });
    {
        layout.open(.{ .width = .grow, .height = .grow, .padding = .all(24) });
        defer layout.close();
        // Orange rather than white. White is the same number in every
        // channel, so it would pass just as happily out of a backend that
        // handed the bytes back as BGRA - and the two backends disagreeing
        // about that is exactly the kind of thing this test is for.
        layout.empty(.{ .width = .grow, .height = .grow, .background_color = .hex(0xFF8000) });
    }
    const commands = try layout.end();

    try renderer.draw(.{ .texture = target }, size, commands, .black);

    const pixels = try device.readTexture(target, testing.allocator);
    defer testing.allocator.free(pixels);

    const channel = struct {
        fn at(data: []const u8, x: usize, y: usize, index: usize) u8 {
            return data[(y * 128 + x) * 4 + index];
        }
    }.at;

    // In the middle: the square, and in the order the format promised.
    try testing.expect(channel(pixels, 64, 64, 0) > 200);
    try testing.expectApproxEqAbs(128, @as(f32, @floatFromInt(channel(pixels, 64, 64, 1))), 8);
    try testing.expect(channel(pixels, 64, 64, 2) < 50);

    // In the corners: the clear colour. Both wrong means the shader did not
    // run; one wrong means it ran upside down or at the wrong scale.
    try testing.expect(channel(pixels, 2, 2, 0) < 50);
    try testing.expect(channel(pixels, 126, 126, 0) < 50);

    // And the edge is where the padding put it.
    try testing.expect(channel(pixels, 30, 64, 0) > 200);
    try testing.expect(channel(pixels, 10, 64, 0) < 50);
}

test "the Direct3D shader turns a box too" {
    var device: rhi.Device = rhi.Device.init(testing.allocator, .{ .backend = .d3d11 }) catch
        return error.SkipZigTest;
    defer device.deinit();
    try testing.expectEqual(rhi.Backend.d3d11, device.backendTag());

    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const target = try device.createTexture(.{
        .width = 128,
        .height = 128,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer device.destroyTexture(target);

    var face: font.Font = try .init(bytes);
    var renderer: Renderer = try .init(testing.allocator, &device, &face);
    defer renderer.deinit();

    const size: ui.Dimensions = .init(128, 128);

    var layout: ui.Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(.monospace(0.5, 1.0));

    layout.begin(.{ .size = size });
    {
        layout.open(.{ .width = .grow, .height = .grow, .align_y = .center });
        defer layout.close();
        layout.empty(.{
            .width = .grow,
            .height = .fixed(24),
            .background_color = .hex(0xFF8000),
            .rotate = .degrees(90),
        });
    }
    const commands = try layout.end();

    try renderer.draw(.{ .texture = target }, size, commands, .black);

    const pixels = try device.readTexture(target, testing.allocator);
    defer testing.allocator.free(pixels);

    const channel = struct {
        fn at(data: []const u8, x: usize, y: usize, index: usize) u8 {
            return data[(y * 128 + x) * 4 + index];
        }
    }.at;

    try testing.expect(channel(pixels, 64, 10, 0) > 200);
    try testing.expect(channel(pixels, 10, 64, 0) < 50);
}

test "the Direct3D shader draws a picture too" {
    // The image branch of the HLSL, which was written beside the GLSL and
    // would otherwise never have run. A `float4` sampled where a `float`
    // was expected, a swizzle in the wrong order, a texture bound to the
    // wrong slot: all of them draw nothing and none of them is an error.
    var device: rhi.Device = rhi.Device.init(testing.allocator, .{ .backend = .d3d11 }) catch
        return error.SkipZigTest;
    defer device.deinit();
    try testing.expectEqual(rhi.Backend.d3d11, device.backendTag());

    const bytes = try systemFont(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(bytes);

    const target = try device.createTexture(.{
        .width = 64,
        .height = 64,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer device.destroyTexture(target);

    // Orange on the left, blue on the right, and only the left is asked for.
    const sheet = try device.createTexture(.{
        .width = 2,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });
    defer device.destroyTexture(sheet);
    try device.updateTexture(sheet, &[_]u8{
        0xFF, 0x80, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
    }, 2 * 4);

    var face: font.Font = try .init(bytes);
    var renderer: Renderer = try .init(testing.allocator, &device, &face);
    defer renderer.deinit();
    renderer.setTextures(&.{sheet});

    const size: ui.Dimensions = .init(64, 64);

    var layout: ui.Ui = .init(testing.allocator);
    defer layout.deinit();
    layout.setMeasurer(.monospace(0.5, 1.0));

    layout.begin(.{ .size = size });
    layout.empty(.{
        .width = .grow,
        .height = .grow,
        .image = .{ .texture = 0, .source = .init(0, 0, 0.5, 1) },
    });
    const commands = try layout.end();

    try renderer.draw(.{ .texture = target }, size, commands, .black);

    const pixels = try device.readTexture(target, testing.allocator);
    defer testing.allocator.free(pixels);

    const middle = (32 * 64 + 32) * 4;
    try testing.expect(pixels[middle] > 200);
    try testing.expectApproxEqAbs(128, @as(f32, @floatFromInt(pixels[middle + 1])), 12);
    try testing.expect(pixels[middle + 2] < 50);
}

test "a picture is one instance, tinted, with the source rectangle as its uv" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const texture = try fixture.device.createTexture(.{
        .width = 4,
        .height = 4,
        .usage = .{ .sampled = true },
    });
    defer fixture.device.destroyTexture(texture);
    fixture.renderer.setTextures(&.{texture});

    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(10, 20, 30, 40), .config = .{ .image = .{
            .texture = 0,
            .source = .init(0.25, 0.5, 0.25, 0.5),
            .tint = .hex(0xFF8000),
        } } },
    }, .init(200, 200));

    const instances = fixture.renderer.instances.items;
    try testing.expectEqual(@as(usize, 1), instances.len);
    try testing.expectEqual(Instance.Kind.image, instances[0].textured);
    // The uv is the source rectangle as two corners, not as a position and a
    // size - which is what the vertex shader interpolates between.
    try testing.expectEqual([4]f32{ 0.25, 0.5, 0.5, 1.0 }, instances[0].uv);
    try testing.expectEqual(ui.Color.hex(0xFF8000).array(), instances[0].color);

    // And the batch asks for that texture rather than the atlas.
    try testing.expectEqual(@as(usize, 1), fixture.renderer.batches.items.len);
    try testing.expect(fixture.renderer.batches.items[0].texture != null);
}

test "the background of an image is a rectangle under it" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const texture = try fixture.device.createTexture(.{
        .width = 4,
        .height = 4,
        .usage = .{ .sampled = true },
    });
    defer fixture.device.destroyTexture(texture);
    fixture.renderer.setTextures(&.{texture});

    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .image = .{
            .texture = 0,
            .background_color = .hex(0x112233),
        } } },
    }, .init(200, 200));

    const instances = fixture.renderer.instances.items;
    try testing.expectEqual(@as(usize, 2), instances.len);
    try testing.expectEqual(Instance.Kind.shape, instances[0].textured);
    try testing.expectEqual(Instance.Kind.image, instances[1].textured);
}

test "a texture nobody registered draws the background and nothing else" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    // No table at all, and a command naming slot seven.
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 10, 10), .config = .{ .image = .{
            .texture = 7,
            .background_color = .hex(0x112233),
        } } },
    }, .init(200, 200));

    // A missing picture rather than a crash.
    try testing.expectEqual(@as(usize, 1), fixture.renderer.instances.items.len);
    try testing.expectEqual(Instance.Kind.shape, fixture.renderer.instances.items[0].textured);
}

test "two pictures from one sheet stay one draw, and two sheets do not" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const one = try fixture.device.createTexture(.{ .width = 4, .height = 4, .usage = .{ .sampled = true } });
    defer fixture.device.destroyTexture(one);
    const two = try fixture.device.createTexture(.{ .width = 4, .height = 4, .usage = .{ .sampled = true } });
    defer fixture.device.destroyTexture(two);
    fixture.renderer.setTextures(&.{ one, two });

    // Two slices of the same sheet: one batch, which is the whole reason the
    // source rectangle is there.
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 16, 16), .config = .{ .image = .{ .texture = 0, .source = .init(0, 0, 0.5, 1) } } },
        .{ .bounding_box = .init(16, 0, 16, 16), .config = .{ .image = .{ .texture = 0, .source = .init(0.5, 0, 0.5, 1) } } },
    }, .init(200, 200));
    try testing.expectEqual(@as(usize, 1), fixture.renderer.batches.items.len);

    // Two different sheets: two batches, because one texture is bound at a
    // time and there is nowhere else to put the second.
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 16, 16), .config = .{ .image = .{ .texture = 0 } } },
        .{ .bounding_box = .init(16, 0, 16, 16), .config = .{ .image = .{ .texture = 1 } } },
    }, .init(200, 200));
    try testing.expectEqual(@as(usize, 2), fixture.renderer.batches.items.len);
}

test "a picture between two labels breaks the batch and the labels rejoin" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const sheet = try fixture.device.createTexture(.{ .width = 4, .height = 4, .usage = .{ .sampled = true } });
    defer fixture.device.destroyTexture(sheet);
    fixture.renderer.setTextures(&.{sheet});

    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 40, 20), .config = .{ .text = .{ .text = "one", .color = .white, .font_size = 16 } } },
        .{ .bounding_box = .init(0, 20, 16, 16), .config = .{ .image = .{ .texture = 0 } } },
        .{ .bounding_box = .init(0, 40, 40, 20), .config = .{ .text = .{ .text = "two", .color = .white, .font_size = 16 } } },
    }, .init(200, 200));

    // Atlas, sheet, atlas: three bindings and so three draws. A shape would
    // have joined whichever of them it landed in.
    try testing.expectEqual(@as(usize, 3), fixture.renderer.batches.items.len);
}

test "a wave moves a glyph and leaves the pen where it was" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    // A wave straight down, standing still, at its crest on the first letter.
    const effects = [_]ui.markup.Effect{.{ .wave = .{
        .cycle = .{ .width = 100, .frequency = 0, .amplitude = 0.5 },
    } }};

    fixture.renderer.setTime(0);
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 200, 20), .config = .{ .text = .{
            .text = "ab",
            .color = .white,
            .font_size = 16,
            .effects = &effects,
        } } },
    }, .init(200, 200));

    try testing.expect(fixture.renderer.instances.items.len >= 2);
    // Copied, because the next build refills the same list - comparing two
    // slices of it would be comparing a thing with itself.
    const with = fixture.renderer.instances.items[0];

    // The same run with no effects, to compare against.
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 200, 20), .config = .{ .text = .{
            .text = "ab",
            .color = .white,
            .font_size = 16,
        } } },
    }, .init(200, 200));
    const without = fixture.renderer.instances.items[0];

    // The box is untouched - a wave moves where a letter is drawn, not where
    // the next one starts, or the word would stretch as it went.
    try testing.expectEqual(without.rect, with.rect);
    // What changed is where the motion puts it: eight pixels down, which is
    // half an em at sixteen.
    try testing.expectApproxEqAbs(@as(f32, 8), with.origin[1] - without.origin[1], 0.01);
}

test "a typewriter hides the letters it has not reached" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const effects = [_]ui.markup.Effect{.{ .reveal = .{
        .kind = .type,
        .speed = 2,
        .clock = 1234,
    } }};

    const frame = struct {
        fn run(f: *Fixture, e: []const ui.markup.Effect) !usize {
            try f.renderer.build(&.{
                .{ .bounding_box = .init(0, 0, 200, 20), .config = .{ .text = .{
                    .text = "abcdef",
                    .color = .white,
                    .font_size = 16,
                    .effects = e,
                } } },
            }, .init(200, 200));
            return f.renderer.instances.items.len;
        }
    }.run;

    // The clock starts on the frame the effect is first seen, so nothing has
    // arrived yet.
    fixture.renderer.setTime(10);
    try testing.expectEqual(@as(usize, 0), try frame(fixture, &effects));

    // A second later, two letters at two a second.
    fixture.renderer.setTime(11);
    try testing.expectEqual(@as(usize, 2), try frame(fixture, &effects));

    // And eventually all of them.
    fixture.renderer.setTime(20);
    try testing.expectEqual(@as(usize, 6), try frame(fixture, &effects));
}

test "a gradient colours the letters differently from each other" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    const effects = [_]ui.markup.Effect{.{ .gradient = .{ .speed = 0 } }};

    fixture.renderer.setTime(0);
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 200, 20), .config = .{ .text = .{
            .text = "abcd",
            .color = .white,
            .font_size = 16,
            .effects = &effects,
        } } },
    }, .init(200, 200));

    const instances = fixture.renderer.instances.items;
    try testing.expect(instances.len >= 2);
    // Ply's rainbow puts a stop at every character, so no two next to each
    // other are the same.
    try testing.expect(!std.meta.eql(instances[0].color, instances[1].color));
}

test "a run with no effects takes the path it always did" {
    const fixture = try Fixture.init(testing.allocator) orelse return error.SkipZigTest;
    defer fixture.deinit(testing.allocator);

    fixture.renderer.setTime(3.5);
    try fixture.renderer.build(&.{
        .{ .bounding_box = .init(0, 0, 200, 20), .config = .{ .text = .{
            .text = "plain",
            .color = .white,
            .font_size = 16,
        } } },
    }, .init(200, 200));

    // Whatever the clock says, an unanimated glyph is not turned.
    for (fixture.renderer.instances.items) |instance| {
        try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, instance.motion);
        try testing.expectEqual([2]f32{ 0, 0 }, instance.origin);
    }
}
