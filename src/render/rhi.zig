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

const Atlas = @import("Atlas.zig");

pub const Error = rhi.types.Error || Atlas.Error;

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
    /// How thick the border is, in pixels. Zero fills the whole box.
    border: f32,
    /// One for a glyph, zero for a shape. A flag rather than two pipelines,
    /// because two pipelines would be two draw calls and a state change
    /// between every label and the box behind it.
    textured: f32,
};

/// What a frame tells the shader. Sixteen bytes, `std140`.
const Frame = extern struct {
    viewport: [4]f32,
};

/// A run of instances drawn under one scissor rectangle.
const Batch = struct {
    first: u32,
    count: u32,
    scissor: ?rhi.types.Rect,
};

const quad_vertices = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,
    face: *const font.Font,

    atlas: Atlas,
    atlas_texture: rhi.types.Texture,
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

        const shader = try device.createShader(.{
            .glsl = .{ .vertex = glsl_vertex, .fragment = glsl_fragment },
            .hlsl = .{ .vertex = hlsl_vertex, .fragment = hlsl_fragment },
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
                .{ .location = 5, .format = .float2, .offset = @offsetOf(Instance, "border"), .buffer = 1 },
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

    pub fn deinit(self: *Renderer) void {
        self.device.destroyBuffer(self.frame_buffer);
        self.device.destroyBuffer(self.instance_buffer);
        self.device.destroyBuffer(self.quad);
        self.device.destroyPipeline(self.pipeline);
        self.device.destroyShader(self.shader);
        self.device.destroySampler(self.sampler);
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
        clear: ui.Color,
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
            .clear_color = clear.array(),
        } });
        try list.setViewport(.{ .width = size.width, .height = size.height });
        try list.setPipeline(self.pipeline);
        try list.setVertexBuffer(0, self.quad, 0);
        try list.setUniformBuffer(0, self.frame_buffer);
        try list.setTexture(0, self.atlas_texture, self.sampler);

        for (self.batches.items) |batch| {
            if (batch.count == 0) continue;
            try list.setScissor(batch.scissor);
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

        for (commands) |command| {
            switch (command.config) {
                .scissor_start => {
                    try self.closeBatch(&batch_start, scissor);
                    const box = command.bounding_box;
                    const wanted = intersect(scissor, box, size);
                    try self.clips.append(self.gpa, wanted);
                    scissor = wanted;
                },
                .scissor_end => {
                    try self.closeBatch(&batch_start, scissor);
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
                    .border = 0,
                    .textured = 0,
                }),
                .border => |line| try self.instances.append(self.gpa, .{
                    .rect = boxArray(command.bounding_box),
                    .color = line.color.array(),
                    .radii = line.corner_radius.array(),
                    .uv = @splat(0),
                    // One width for all four sides. Four different ones would
                    // need four quads, and no interface has ever asked.
                    .border = @floatFromInt(@max(
                        @max(line.width.left, line.width.right),
                        @max(line.width.top, line.width.bottom),
                    )),
                    .textured = 0,
                }),
                .text => |run| try self.addText(command, run),
                .none, .image => {},
            }
        }

        try self.closeBatch(&batch_start, scissor);
    }

    /// One instance per glyph of a line.
    fn addText(self: *Renderer, command: ui.RenderCommand, run: ui.commands.Text) Error!void {
        const size: u16 = run.font_size;
        const scale = self.face.scaleFor(@floatFromInt(size));

        // The command's box is the line; the baseline is one ascent down it.
        const baseline = command.bounding_box.y + self.face.at(@floatFromInt(size)).ascent();
        var pen = command.bounding_box.x;
        var previous: ?u16 = null;

        var letters = (std.unicode.Utf8View.init(run.text) catch return).iterator();
        while (letters.nextCodepoint()) |codepoint| {
            const index = self.face.glyphFor(codepoint);
            if (previous) |left| {
                pen += @as(f32, @floatFromInt(self.face.kern(left, index) catch 0)) * scale;
            }
            previous = index;

            const entry = try self.atlas.glyph(self.face, index, size);
            if (!entry.isBlank()) {
                try self.instances.append(self.gpa, .{
                    .rect = .{
                        pen + @as(f32, @floatFromInt(entry.left)),
                        baseline - @as(f32, @floatFromInt(entry.top)),
                        @floatFromInt(entry.width),
                        @floatFromInt(entry.height),
                    },
                    .color = run.color.array(),
                    .radii = @splat(0),
                    .uv = .{ entry.u0, entry.v0, entry.u1, entry.v1 },
                    .border = 0,
                    .textured = 1,
                });
            }
            pen += entry.advance;
        }
    }

    fn closeBatch(self: *Renderer, first: *u32, scissor: ?rhi.types.Rect) Allocator.Error!void {
        const now: u32 = @intCast(self.instances.items.len);
        if (now > first.*) {
            try self.batches.append(self.gpa, .{
                .first = first.*,
                .count = now - first.*,
                .scissor = scissor,
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

/// The signed distance to a rounded box, and the whole reason one pipeline
/// can draw every shape a UI has.
///
/// Negative inside, positive outside, and the value is the distance in
/// pixels - so `0.5 - d` clamped to zero and one is a one-pixel antialiased
/// edge that needs no multisampling and no extra geometry. Iñigo Quílez's,
/// with the four corners split out.
const glsl_vertex =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in vec4 a_rect;
    \\layout(location = 2) in vec4 a_color;
    \\layout(location = 3) in vec4 a_radii;
    \\layout(location = 4) in vec4 a_uv;
    \\layout(location = 5) in vec2 a_params;
    \\
    \\layout(std140) uniform Frame { vec4 u_viewport; };
    \\
    \\out vec2 v_local;
    \\out vec2 v_half;
    \\out vec4 v_color;
    \\out vec4 v_radii;
    \\out vec2 v_uv;
    \\out float v_border;
    \\out float v_textured;
    \\
    \\void main() {
    \\    vec2 pixel = a_rect.xy + a_corner * a_rect.zw;
    \\    v_local = (a_corner - 0.5) * a_rect.zw;
    \\    v_half = a_rect.zw * 0.5;
    \\    v_color = a_color;
    \\    v_radii = a_radii;
    \\    v_uv = mix(a_uv.xy, a_uv.zw, a_corner);
    \\    v_border = a_params.x;
    \\    v_textured = a_params.y;
    \\    gl_Position = vec4(pixel.x / u_viewport.x * 2.0 - 1.0,
    \\                       1.0 - pixel.y / u_viewport.y * 2.0, 0.0, 1.0);
    \\}
;

const glsl_fragment =
    \\#version 330 core
    \\in vec2 v_local;
    \\in vec2 v_half;
    \\in vec4 v_color;
    \\in vec4 v_radii;
    \\in vec2 v_uv;
    \\in float v_border;
    \\in float v_textured;
    \\
    \\uniform sampler2D u_atlas;
    \\out vec4 o_color;
    \\
    \\float roundedBox(vec2 p, vec2 b, vec4 r) {
    \\    float radius = (p.x > 0.0) ? ((p.y < 0.0) ? r.y : r.z)
    \\                               : ((p.y < 0.0) ? r.x : r.w);
    \\    vec2 q = abs(p) - b + radius;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
    \\}
    \\
    \\void main() {
    \\    if (v_textured > 0.5) {
    \\        o_color = vec4(v_color.rgb, v_color.a * texture(u_atlas, v_uv).r);
    \\        return;
    \\    }
    \\
    \\    float outer = roundedBox(v_local, v_half, v_radii);
    \\    float alpha = clamp(0.5 - outer, 0.0, 1.0);
    \\
    \\    if (v_border > 0.0) {
    \\        vec4 inner_radii = max(v_radii - v_border, vec4(0.0));
    \\        float inner = roundedBox(v_local, max(v_half - v_border, vec2(0.0)), inner_radii);
    \\        alpha *= clamp(0.5 + inner, 0.0, 1.0);
    \\    }
    \\
    \\    o_color = vec4(v_color.rgb, v_color.a * alpha);
    \\}
;

const hlsl_vertex =
    \\cbuffer Frame : register(b0) { float4 u_viewport; };
    \\
    \\struct Input {
    \\    float2 corner : ATTR0;
    \\    float4 rect   : ATTR1;
    \\    float4 color  : ATTR2;
    \\    float4 radii  : ATTR3;
    \\    float4 uv     : ATTR4;
    \\    float2 params : ATTR5;
    \\};
    \\
    \\struct Output {
    \\    float4 position : SV_POSITION;
    \\    float2 local    : TEXCOORD0;
    \\    float2 half_    : TEXCOORD1;
    \\    float4 color    : TEXCOORD2;
    \\    float4 radii    : TEXCOORD3;
    \\    float2 uv       : TEXCOORD4;
    \\    float2 params   : TEXCOORD5;
    \\};
    \\
    \\Output main(Input input) {
    \\    Output output;
    \\    float2 pixel = input.rect.xy + input.corner * input.rect.zw;
    \\    output.local = (input.corner - 0.5) * input.rect.zw;
    \\    output.half_ = input.rect.zw * 0.5;
    \\    output.color = input.color;
    \\    output.radii = input.radii;
    \\    output.uv = lerp(input.uv.xy, input.uv.zw, input.corner);
    \\    output.params = input.params;
    \\    output.position = float4(pixel.x / u_viewport.x * 2.0 - 1.0,
    \\                             1.0 - pixel.y / u_viewport.y * 2.0, 0.0, 1.0);
    \\    return output;
    \\}
;

const hlsl_fragment =
    \\Texture2D u_atlas : register(t0);
    \\SamplerState u_atlas_sampler : register(s0);
    \\
    \\struct Input {
    \\    float4 position : SV_POSITION;
    \\    float2 local    : TEXCOORD0;
    \\    float2 half_    : TEXCOORD1;
    \\    float4 color    : TEXCOORD2;
    \\    float4 radii    : TEXCOORD3;
    \\    float2 uv       : TEXCOORD4;
    \\    float2 params   : TEXCOORD5;
    \\};
    \\
    \\float roundedBox(float2 p, float2 b, float4 r) {
    \\    float radius = (p.x > 0.0) ? ((p.y < 0.0) ? r.y : r.z)
    \\                               : ((p.y < 0.0) ? r.x : r.w);
    \\    float2 q = abs(p) - b + radius;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
    \\}
    \\
    \\float4 main(Input input) : SV_TARGET {
    \\    if (input.params.y > 0.5) {
    \\        float coverage = u_atlas.Sample(u_atlas_sampler, input.uv).r;
    \\        return float4(input.color.rgb, input.color.a * coverage);
    \\    }
    \\
    \\    float outer = roundedBox(input.local, input.half_, input.radii);
    \\    float alpha = saturate(0.5 - outer);
    \\
    \\    if (input.params.x > 0.0) {
    \\        float4 inner_radii = max(input.radii - input.params.x, 0.0);
    \\        float2 inner_half = max(input.half_ - input.params.x, 0.0);
    \\        float inner = roundedBox(input.local, inner_half, inner_radii);
    \\        alpha *= saturate(0.5 + inner);
    \\    }
    \\
    \\    return float4(input.color.rgb, input.color.a * alpha);
    \\}
;

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

    layout.begin(page);
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

    layout.begin(size);
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
