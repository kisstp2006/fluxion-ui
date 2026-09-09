#version 330 core
in vec2 v_local;
in vec2 v_half;
in vec4 v_color;
in vec4 v_radii;
in vec2 v_uv;
in float v_border;
in float v_textured;

uniform sampler2D u_atlas;
out vec4 o_color;

float roundedBox(vec2 p, vec2 b, vec4 r) {
    float radius = (p.x > 0.0) ? ((p.y < 0.0) ? r.y : r.z)
                               : ((p.y < 0.0) ? r.x : r.w);
    vec2 q = abs(p) - b + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void main() {
    // A glyph is one channel of coverage and has no box of its own, so
    // it leaves before the distance field is computed.
    if (v_textured > 0.5 && v_textured < 1.5) {
        o_color = vec4(v_color.rgb, v_color.a * texture(u_atlas, v_uv).r);
        return;
    }

    float outer = roundedBox(v_local, v_half, v_radii);
    float alpha = clamp(0.5 - outer, 0.0, 1.0);

    // A picture is all four channels, tinted, and cut to the same
    // rounded box a rectangle would be - so a rounded avatar is round.
    if (v_textured > 1.5) {
        vec4 texel = texture(u_atlas, v_uv);
        o_color = vec4(texel.rgb * v_color.rgb, texel.a * v_color.a * alpha);
        return;
    }

    if (v_border > 0.0) {
        vec4 inner_radii = max(v_radii - v_border, vec4(0.0));
        float inner = roundedBox(v_local, max(v_half - v_border, vec2(0.0)), inner_radii);
        alpha *= clamp(0.5 + inner, 0.0, 1.0);
    }

    o_color = vec4(v_color.rgb, v_color.a * alpha);
}
