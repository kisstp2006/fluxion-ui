cbuffer Frame : register(b0) { float4 u_viewport; };

struct Input {
    float2 corner : ATTR0;
    float4 rect   : ATTR1;
    float4 color  : ATTR2;
    float4 radii  : ATTR3;
    float4 uv     : ATTR4;
    float4 params : ATTR5;
    float4 motion : ATTR6;
};

struct Output {
    float4 position : SV_POSITION;
    float2 local    : TEXCOORD0;
    float2 half_    : TEXCOORD1;
    float4 color    : TEXCOORD2;
    float4 radii    : TEXCOORD3;
    float2 uv       : TEXCOORD4;
    float4 params   : TEXCOORD5;
};

Output main(Input input) {
    Output output;
    float2 pixel = input.rect.xy + input.corner * input.rect.zw;
    pixel = float2(input.motion.x * pixel.x + input.motion.z * pixel.y,
                   input.motion.y * pixel.x + input.motion.w * pixel.y) + input.params.zw;
    output.local = (input.corner - 0.5) * input.rect.zw;
    output.half_ = input.rect.zw * 0.5;
    output.color = input.color;
    output.radii = input.radii;
    output.uv = lerp(input.uv.xy, input.uv.zw, input.corner);
    output.params = input.params;
    output.position = float4(pixel.x / u_viewport.x * 2.0 - 1.0,
                             1.0 - pixel.y / u_viewport.y * 2.0, 0.0, 1.0);
    return output;
}
