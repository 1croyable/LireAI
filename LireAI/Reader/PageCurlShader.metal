#include <metal_stdlib>
using namespace metal;

struct PageCurlVertex {
    float4 position;
    float4 textureInfo;
};

struct PageCurlVarying {
    float4 position [[position]];
    float2 uv;
    float2 shadowUV;
    float backside;
    float illumination;
    float elevation;
    float shadowAlpha;
};

struct ShadowUniforms {
    float4 fold;
    float4 edge;
    float4 viewport;
    float4 paper;
    float4 surface;
};

struct PageCurlSurface {
    float2 point;
    float lift;
    float angle;
};

PageCurlSurface curlSurface(float2 point, constant ShadowUniforms &shadows) {
    PageCurlSurface result;
    result.point = point;
    result.lift = 0.0;
    result.angle = 0.0;
    if (shadows.surface.w <= 0.5) { return result; }

    float2 midpoint = shadows.fold.xy;
    float2 normal = normalize(shadows.fold.zw);
    float signedDistance = dot(point - midpoint, normal);
    if (signedDistance >= 0.0) { return result; }

    float radius = max(8.0, shadows.viewport.w);
    float distance = -signedDistance;
    float arcLength = M_PI_F * radius;
    float normalPosition;
    if (distance < arcLength) {
        result.angle = distance / radius;
        normalPosition = -radius * sin(result.angle);
        result.lift = radius * (1.0 - cos(result.angle));
    } else {
        result.angle = M_PI_F;
        normalPosition = distance - arcLength;
        result.lift = 2.0 * radius;
    }
    float2 foot = point - signedDistance * normal;
    result.point = foot + normalPosition * normal;
    return result;
}

vertex PageCurlVarying pageCurlVertex(const device PageCurlVertex *vertices [[buffer(0)]],
                                      constant ShadowUniforms &shadows [[buffer(2)]],
                                      uint index [[vertex_id]]) {
    PageCurlVertex source = vertices[index];
    PageCurlVarying result;
    result.uv = source.textureInfo.xy;
    result.shadowUV = source.textureInfo.xy;
    result.backside = 0.0;
    result.illumination = 1.0;
    result.elevation = 0.0;
    result.shadowAlpha = 1.0;

    if (source.position.w < 0.5) {
        result.position = float4(source.position.xyz, 1.0);
        return result;
    }

    float2 size = max(shadows.viewport.xy, float2(1.0));
    float2 point = source.position.xy * size;
    PageCurlSurface surface = curlSurface(point, shadows);
    float2 screenPoint = surface.point;
    result.shadowUV = screenPoint / size;
    float lift = surface.lift;
    float radius = max(8.0, shadows.viewport.w);
    result.backside = smoothstep(0.42 * M_PI_F, 0.58 * M_PI_F, surface.angle);
    result.illumination = 1.0;
    result.elevation = clamp(lift / max(2.0 * radius, 1.0), 0.0, 1.0);

    float2 clip = float2(2.0 * screenPoint.x / size.x - 1.0,
                         1.0 - 2.0 * screenPoint.y / size.y);
    float depth = 0.50 - min(lift / max(size.y, 1.0), 0.35);
    if (shadows.viewport.z > 1.5 && shadows.viewport.z < 2.5) {
        depth = 0.50;
    }
    result.position = float4(clip, depth, 1.0);
    return result;
}

fragment float4 pageCurlFragment(PageCurlVarying input [[stage_in]],
                                  texture2d<float> page [[texture(0)]],
                                  texture2d<float> castShadow [[texture(1)]],
                                  constant float &opacity [[buffer(0)]],
                                  constant ShadowUniforms &shadows [[buffer(1)]]) {
    constexpr sampler paperSampler(filter::linear, address::clamp_to_edge);
    float4 frontInk = page.sample(paperSampler, input.uv);

    if (shadows.viewport.z > 1.5 && shadows.viewport.z < 2.5) {
        float awayFromSpine = smoothstep(0.015, 0.08, input.uv.x);
        float lifted = smoothstep(0.005, 0.16, input.elevation);
        return float4(1.0, 1.0, 1.0, opacity * awayFromSpine * lifted);
    }

    if (shadows.viewport.z > 2.5 && shadows.viewport.z < 3.5) {
        return float4(0.018, 0.016, 0.013,
                      frontInk.a * max(0.0, shadows.surface.y));
    }

    if (shadows.viewport.z > 0.5 && shadows.viewport.z < 1.5) {
        return float4(frontInk.rgb, opacity);
    }

    float3 paperColor = shadows.paper.rgb;
    float3 highlightedPaper = min(float3(1.0), paperColor + float3(0.030));
    float3 inkDelta = frontInk.rgb - paperColor;
    float3 paperBack = clamp(highlightedPaper + inkDelta * 0.31, 0.0, 1.0);
    float backAmount = smoothstep(0.04, 0.96, input.backside);
    float3 color = mix(frontInk.rgb, paperBack, backAmount);
    float receiver = 1.0 - smoothstep(0.005, 0.05, input.elevation);
    float selfShadow = castShadow.sample(paperSampler, input.shadowUV).a;
    color *= 1.0 - 0.40 * receiver * selfShadow;
    return float4(color, opacity);
}
