// Warp algorithm ported from @kawarp/core 1.3.1 (MIT), Copyright (c) 2026 Better Lyrics.
// https://github.com/better-lyrics/kawarp — bundled notice: Kawarp-LICENSE.txt.
#include <metal_stdlib>
using namespace metal;
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle strip — no vertex buffer needed, positions are
// derived from vertex_id, which is the standard trick for full-screen
// post-process passes like this.
vertex VertexOut karaoke_bg_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    VertexOut out;
    float2 p = positions[vertexID];
    out.position = float4(p, 0, 1);
    // Flip Y for UV since Metal's clip space Y is opposite texture-space Y.
    out.uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5);
    return out;
}

// Simplex-noise-ish value noise (a cheap 2D gradient noise approximation —
// not bit-identical to true simplex noise, but produces the same kind of
// smooth, organic-looking field that's all domain warping actually needs;
// a from-scratch simplex implementation would be considerably more code
// for a visual difference that isn't meaningfully perceptible here).
  float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
  float2 mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
  float3 permute(float3 x) { return mod289(((x*34.0)+1.0)*x); }

  float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                        -0.577350269189626, 0.024390243902439);
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m; m = m*m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
  }


struct KaraokeBgParams {
    float time;
    float warpIntensity;
    float blurRadius;
    float blendProgress;
};
fragment float4 karaoke_bg_fragment(VertexOut in [[stage_in]],
    texture2d<float> albumArt [[texture(0)]], texture2d<float> previousArt [[texture(1)]],
    constant KaraokeBgParams &params [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float t = params.time * 0.05;

    float2 center = uv - 0.5;
    float centerWeight = 1.0 - smoothstep(0.0, 0.7, length(center));

    // Large-scale movement (slow, big blobs)
    float n1 = snoise(uv * 0.35 + float2(t, t * 0.7));
    float n2 = snoise(uv * 0.35 + float2(-t * 0.8, t * 0.5) + float2(50.0, 50.0));

    // Medium-scale detail (adds organic movement)
    float n3 = snoise(uv * 0.9 + float2(t * 1.2, -t) + float2(100.0, 0.0));
    float n4 = snoise(uv * 0.9 + float2(-t, t * 1.1) + float2(0.0, 100.0));

    // Combine two octaves
    float2 warp = float2(
      n1 * 0.65 + n3 * 0.35,
      n2 * 0.65 + n4 * 0.35
    ) * centerWeight;

    float2 warpedUV = uv + warp * params.warpIntensity;
    warpedUV = clamp(warpedUV, 0.0, 1.0);


    float blend = smoothstep(0.0, 1.0, params.blendProgress);
    float4 color = float4(0);
    for (int i = 0; i < 8; i++) {
        float angle = (float(i) / 8.0) * 6.2831853;
        float2 tap = float2(cos(angle), sin(angle)) * params.blurRadius;
        color += mix(previousArt.sample(s, warpedUV + tap), albumArt.sample(s, warpedUV + tap), blend);
    }
    color *= 0.125;
    float2 centerUV = in.uv - 0.5;
    color.rgb *= 1.0 - dot(centerUV, centerUV) * 0.3;
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(float3(gray), color.rgb, 1.5);
    float2 pixels = floor(in.uv * float2(albumArt.get_width(), albumArt.get_height()));
    float grain = fract(sin(dot(pixels + floor(params.time * 60.0), float2(12.9898, 78.233))) * 43758.5453);
    color.rgb += (grain - 0.5) * 0.008;
    return float4(clamp(color.rgb, 0.0, 1.0), 1.0);
}
