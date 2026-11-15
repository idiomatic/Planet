let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4 sun;        // xyz: unit vector toward the sun
    float4 elevation;  // x: min, y: sea level, z: max (meters); w: 1 when drawing mesh edges
    float4 display;    // x: radii per meter of elevation, with exaggeration
    float4 camera;     // xyz: position, in radii
    float4 lod;        // x: pixels per radian, y: split threshold in pixels, z: 1 to blend levels,
                       // w: blend band, as a fraction of the threshold
};

// A patch vertex, as the core writes it.
struct Vertex {
    packed_float3 direction;
    float elevation;   // meters
    packed_float3 gradient; // tangential elevation gradient, meters per radian
    float skirt;       // 1 on a skirt's lower edge
    float parentElevation;  // what the parent patch shows here
    packed_float3 parentGradient;
};

struct PatchConstants {
    float skirtDepth;  // radii
    float parentEdge;  // the parent's lattice triangle edge, in radii; 0 without a parent
};

struct Fragment {
    float4 position [[position]];
    float3 normal;
    float elevation;
};

vertex Fragment vertexMain(uint id [[vertex_id]],
                           const device Vertex *vertices [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]],
                           constant PatchConstants &patch [[buffer(2)]]) {
    Vertex v = vertices[id];
    float3 d = float3(v.direction);
    float s = u.display.x;
    float sea = u.elevation.y;

    // Blend from the parent's shape, where the parent would just have split (its triangles at
    // the threshold), to this patch's own, by the time they're half again larger (the blend
    // band, lod.w). It must end before this patch splits (at twice the threshold) across the
    // whole patch, whose far side lies about 15% farther than its near side.
    float morph = 1;
    if (u.lod.z > 0 && patch.parentEdge > 0) {
        float distance = length(d * (1 + s * max(v.elevation, sea)) - u.camera.xyz);
        float pixels = patch.parentEdge / max(distance, 1e-7) * u.lod.x;
        morph = saturate((pixels / u.lod.y - 1) / u.lod.w);
    }
    float e = mix(v.parentElevation, v.elevation, morph);
    float3 g = mix(float3(v.parentGradient), float3(v.gradient), morph);

    // Oceans are flat at sea level; skirts hang below the patch's edges to hide cracks.
    float r = 1 + s * max(e, sea) - patch.skirtDepth * v.skirt;
    Fragment out;
    out.position = u.viewProjection * float4(d * r, 1);
    out.normal = e < sea ? d : normalize(d * (1 + s * e) - s * g);
    out.elevation = e;
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
