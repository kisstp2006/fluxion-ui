#version 330 core
layout(location = 0) in vec2 a_corner;
layout(location = 1) in vec4 a_rect;
layout(location = 2) in vec4 a_color;
layout(location = 3) in vec4 a_radii;
layout(location = 4) in vec4 a_uv;
layout(location = 5) in vec4 a_params;
layout(location = 6) in vec4 a_motion;

layout(std140) uniform Frame { vec4 u_viewport; };

out vec2 v_local;
out vec2 v_half;
out vec4 v_color;
out vec4 v_radii;
out vec2 v_uv;
out float v_border;
out float v_textured;

void main() {
    vec2 pixel = a_rect.xy + a_corner * a_rect.zw;
    // Only the position turns. Everything below is in the box's own
    // frame and stays there, which is what keeps a turned corner round
    // and its edge one pixel wide.
    pixel = vec2(a_motion.x * pixel.x + a_motion.z * pixel.y,
                 a_motion.y * pixel.x + a_motion.w * pixel.y) + a_params.zw;
    v_local = (a_corner - 0.5) * a_rect.zw;
    v_half = a_rect.zw * 0.5;
    v_color = a_color;
    v_radii = a_radii;
    v_uv = mix(a_uv.xy, a_uv.zw, a_corner);
    v_border = a_params.x;
    v_textured = a_params.y;
    gl_Position = vec4(pixel.x / u_viewport.x * 2.0 - 1.0,
                       1.0 - pixel.y / u_viewport.y * 2.0, 0.0, 1.0);
}
