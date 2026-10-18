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
float2 hash22(float2 p) {
    float n = sin(dot(p, float2(41.3, 289.1)));
    return fract(float2(262144.0, 32768.0) * n) * 2.0 - 1.0;
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = dot(hash22(i + float2(0, 0)), f - float2(0, 0));
    float b = dot(hash22(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(hash22(i + float2(0, 1)), f - float2(0, 1));
    float d = dot(hash22(i + float2(1, 1)), f - float2(1, 1));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

struct KaraokeBgParams {
    float time;
    float warpIntensity;  // matches Kawarp's warpIntensity option (0-1)
    float blurRadius;     // approximates blurPasses' visual effect
    float blendProgress;
};

fragment float4 karaoke_bg_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> albumArt [[texture(0)]],
    texture2d<float> previousArt [[texture(1)]],
    constant KaraokeBgParams &params [[buffer(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    // Domain warp: offset the sample UV by a slowly-evolving noise field,
    // the same core idea as Kawarp's simplex-noise warping — distorting
    // where we sample from, rather than the pixel colors directly, is
    // what gives the "fluid" look rather than a static blur.
    // Keep the flow clock continuous while tracks and textures change.
    float angle = 0.10 * sin(params.time * 0.11);
    float2 centered = in.uv - 0.5;
    float2 rotated = float2(centered.x * cos(angle) - centered.y * sin(angle),
                            centered.x * sin(angle) + centered.y * cos(angle));
    float2 drift = float2(sin(params.time * 0.17), cos(params.time * 0.13)) * 0.07;
    float2 baseUV = rotated / (1.18 + 0.03 * sin(params.time * 0.09)) + 0.5 + drift;
    float2 warpUV = baseUV * 2.8 + float2(params.time * 0.14, params.time * 0.10);
    float2 offset = float2(valueNoise(warpUV), valueNoise(warpUV + float2(7.3, 2.1)))
        * params.warpIntensity * 0.15;
    float2 sampleUV = clamp(baseUV + offset, 0.0, 1.0);
    float blend = smoothstep(0.0, 1.0, params.blendProgress);
    float4 color = float4(0);
    const int taps = 8;
    for (int i = 0; i < taps; i++) {
        float angle = (float(i) / float(taps)) * 6.28318;
        float2 tapOffset = float2(cos(angle), sin(angle)) * params.blurRadius;
        float2 uv = sampleUV + tapOffset;
        color += mix(previousArt.sample(s, uv), albumArt.sample(s, uv), blend);
    }
    color /= float(taps);

    return color;
}
