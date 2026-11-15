let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4 sun;        // xyz: unit vector toward the sun
    float4 elevation;  // x: min, y: sea level, z: max (meters); w: 1 when drawing mesh edges
};

struct Vertex {
    packed_float3 position;
    packed_float3 normal;
    float elevation;
};

struct Fragment {
    float4 position [[position]];
    float3 normal;
    float elevation;
};

vertex Fragment vertexMain(uint id [[vertex_id]],
                           const device Vertex *vertices [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    Vertex v = vertices[id];
    Fragment out;
    out.position = u.viewProjection * float4(float3(v.position), 1);
    out.normal = float3(v.normal);
    out.elevation = v.elevation;
    return out;
}

static float3 surfaceColor(float e, float4 range) {
    float sea = range.y;
    if (e < sea) {
        float depth = saturate((sea - e) / max(sea - range.x, 1.0));
        return mix(float3(0.10, 0.32, 0.50), float3(0.01, 0.04, 0.16), sqrt(depth));
    }
    float h = saturate((e - sea) / max(range.z - sea, 1.0));
    if (h < 0.02) return float3(0.70, 0.64, 0.46);
    if (h < 0.40) return mix(float3(0.18, 0.40, 0.14), float3(0.36, 0.40, 0.20), (h - 0.02) / 0.38);
    if (h < 0.75) return mix(float3(0.36, 0.40, 0.20), float3(0.42, 0.33, 0.24), (h - 0.40) / 0.35);
    return mix(float3(0.42, 0.33, 0.24), float3(0.95, 0.95, 0.97), saturate((h - 0.75) / 0.1));
}

fragment float4 fragmentMain(Fragment in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float light = saturate(dot(n, u.sun.xyz));
    if (u.elevation.w > 0.5) return float4(float3(0.75, 0.85, 1.0) * (0.25 + 0.5 * light), 1); // mesh edges
    return float4(surfaceColor(in.elevation, u.elevation) * (0.03 + light), 1);
}
"""
