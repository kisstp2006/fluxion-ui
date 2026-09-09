Texture2D u_atlas : register(t0);
SamplerState u_atlas_sampler : register(s0);

struct Input {
    float4 position : SV_POSITION;
    float2 local    : TEXCOORD0;
    float2 half_    : TEXCOORD1;
    float4 color    : TEXCOORD2;
    float4 radii    : TEXCOORD3;
    float2 uv       : TEXCOORD4;
    float4 params   : TEXCOORD5;
};

float roundedBox(float2 p, float2 b, float4 r) {
    float radius = (p.x > 0.0) ? ((p.y < 0.0) ? r.y : r.z)
                               : ((p.y < 0.0) ? r.x : r.w);
    float2 q = abs(p) - b + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float4 main(Input input) : SV_TARGET {
    if (input.params.y > 0.5 && input.params.y < 1.5) {
        float coverage = u_atlas.Sample(u_atlas_sampler, input.uv).r;
        return float4(input.color.rgb, input.color.a * coverage);
    }

    float outer = roundedBox(input.local, input.half_, input.radii);
    float alpha = saturate(0.5 - outer);

    if (input.params.y > 1.5) {
        float4 texel = u_atlas.Sample(u_atlas_sampler, input.uv);
        return float4(texel.rgb * input.color.rgb, texel.a * input.color.a * alpha);
    }

    if (input.params.x > 0.0) {
        float4 inner_radii = max(input.radii - input.params.x, 0.0);
        float2 inner_half = max(input.half_ - input.params.x, 0.0);
        float inner = roundedBox(input.local, inner_half, inner_radii);
        alpha *= saturate(0.5 + inner);
    }

    return float4(input.color.rgb, input.color.a * alpha);
}
