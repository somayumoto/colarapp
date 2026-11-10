#include <metal_stdlib>
using namespace metal;

struct ComparisonUniforms {
    float2 viewportSize;
    float2 sourceSize;
    float4 range;         // Y offset, Y scale, chroma center, chroma scale
    float4 coefficients;  // R/Cr, G/Cb, G/Cr, B/Cb
    int4 flags;           // mode, clockwise quarter turns, demo, aspect fill
    float4 parameters;    // conversion intensity
};

struct ComparisonVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ComparisonVertex comparisonVertex(uint index [[vertex_id]]) {
    const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    float2 p = positions[index];
    return {float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5)};
}

inline float3 demoColor(float2 uv) {
    const float3 colors[] = {
        float3(1, 0, 0), float3(1, 0.4, 0), float3(1, 1, 0), float3(0, 1, 0),
        float3(0, 1, 1), float3(0, 0, 1), float3(1, 0, 1)
    };
    if (uv.y < 0.65) {
        return colors[min(uint(uv.x * 7), 6u)];
    }
    // A white-to-black neutral ramp makes the difference between the modes visible.
    return float3(1 - floor(min(uv.x, 0.9999f) * 7) / 6);
}

inline float2 nativeUV(float2 uv, int quarterTurns) {
    switch (quarterTurns) {
        case 1: return float2(uv.y, 1 - uv.x);
        case 2: return 1 - uv;
        case 3: return float2(1 - uv.y, uv.x);
        default: return uv;
    }
}

inline float3 mappedColor(float3 rgb, int mode) {
    switch (mode) {
        case 0: return float3(0, 0, rgb.r);
        case 1: return rgb.bgr;
        case 2: {
            float gray = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float redDominance = max(0.0f, rgb.r - max(rgb.g, rgb.b));
            return mix(float3(gray), float3(0, 0, 1), redDominance);
        }
        default: return rgb;
    }
}

fragment half4 comparisonFragment(
    ComparisonVertex in [[stage_in]],
    constant ComparisonUniforms &u [[buffer(0)]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]]
) {
    constexpr sampler cameraSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    bool top = in.uv.y < 0.5;
    float2 panelUV = float2(in.uv.x, fract(in.uv.y * 2));
    float2 panelSize = float2(u.viewportSize.x, u.viewportSize.y * 0.5);
    float2 orientedSize = (u.flags.y % 2 == 0) ? u.sourceSize : u.sourceSize.yx;
    float2 ratios = panelSize / orientedSize;
    float scale = u.flags.w != 0 ? max(ratios.x, ratios.y) : min(ratios.x, ratios.y);
    float2 uv = (panelUV - 0.5) * panelSize / (orientedSize * scale) + 0.5;
    if (any(uv < 0) || any(uv > 1)) {
        return half4(0.025h, 0.03h, 0.045h, 1);
    }
    uv = nativeUV(uv, u.flags.y);

    float3 rgb;
    if (u.flags.z != 0) {
        rgb = demoColor(uv);
    } else {
        float y = (luma.sample(cameraSampler, uv).r - u.range.x) * u.range.y;
        float2 cbcr = (chroma.sample(cameraSampler, uv).rg - u.range.z) * u.range.w;
        rgb = clamp(float3(
            y + u.coefficients.x * cbcr.y,
            y + u.coefficients.y * cbcr.x + u.coefficients.z * cbcr.y,
            y + u.coefficients.w * cbcr.x
        ), 0.0f, 1.0f);
    }
    if (top) {
        rgb = mix(rgb, mappedColor(rgb, u.flags.x), u.parameters.x);
    }
    return half4(half3(rgb), 1);
}
