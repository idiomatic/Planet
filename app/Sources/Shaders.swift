let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4 cameraRight;   // xyz: camera's right, w: tan(half the horizontal field of view)
    float4 cameraUp;      // xyz: camera's up, w: tan(half the vertical field of view)
    float4 cameraForward; // xyz: camera's view direction
    float4 sun;        // xyz: unit vector toward the sun
    float4 elevation;  // x: min, y: sea level, z: max (meters); w: 1 when drawing mesh edges
    float4 display;    // x: radii per meter of elevation, with exaggeration
    float4 camera;     // xyz: position, in radii; w: the air's density, relative to Earth's
    float4 lod;        // x: pixels per radian, y: split threshold in pixels, z: 1 to blend levels,
                       // w: blend band, as a fraction of the threshold
    float4 atmosphere; // x: 1 when on, y: meters per radius for the air (see Atmosphere below),
                       // z: radius of the top of the air, w: exposure
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
    float3 world;
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
    out.world = d * r;
    out.position = u.viewProjection * float4(out.world, 1);
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

// Atmosphere: single scattering, raymarched, with Earth's Rayleigh and Mie coefficients.
// Lengths are in radii; the air sees a planet whose radius is atmosphere.y meters, the true
// radius divided by the exaggeration, so the air's thickness keeps its proportion to the
// exaggerated relief while its vertical optical depth stays Earth's.
constant float3 rayleighScattering = float3(5.802e-6, 13.558e-6, 33.1e-6); // per meter
constant float mieScattering = 3.996e-6;
constant float mieExtinction = 4.440e-6;
constant float rayleighHeight = 8000;  // meters
constant float mieHeight = 1200;
constant float mieG = 0.8;
constant float sunIntensity = 20;
constant int sunSteps = 6;

// Distances along the ray to where it enters and leaves a sphere; leaves < enters on a miss.
static float2 raySphere(float3 origin, float3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    float h = b * b - c;
    if (h < 0) return float2(1e30, -1e30);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// Distance along the ray to where it first enters a sphere from outside, or -1 if it doesn't.
static float rayHits(float3 origin, float3 direction, float radius) {
    float2 t = raySphere(origin, direction, radius);
    return t.y >= t.x && t.x > 0 ? t.x : -1;
}

// Rayleigh and Mie densities, relative to sea level.
static float2 airDensity(float3 p, float metersPerRadius, float scale) {
    float height = max(length(p) - 1, 0.0) * metersPerRadius;
    return scale * exp(-height / float2(rayleighHeight, mieHeight));
}

static float3 extinction(float2 opticalDepth) {
    return exp(-(rayleighScattering * opticalDepth.x + mieExtinction * opticalDepth.y));
}

// The fraction of sunlight reaching p, through the air (none where the planet is in the way).
static float3 sunTransmittance(float3 p, float3 sun, float4 atmosphere, float density) {
    if (rayHits(p, sun, 0.999) > 0) return 0;
    float length = raySphere(p, sun, atmosphere.z).y;
    float ds = length / sunSteps;
    float2 depth = 0;
    for (int i = 0; i < sunSteps; i++) {
        depth += airDensity(p + sun * (ds * (i + 0.5)), atmosphere.y, density) * ds * atmosphere.y;
    }
    return extinction(depth);
}

struct Scattering {
    float3 inscattered;   // light scattered toward the camera along the ray
    float3 transmittance; // what's left of the light from the ray's end
};

// Scattering along the ray from origin in direction (unit), up to maxDistance.
// `jitter` (0...1, varying by pixel) offsets the samples, trading banding for fine noise.
static Scattering scatter(float3 origin, float3 direction, float maxDistance, float3 sun, float4 atmosphere,
                          int viewSteps, float jitter, float density) {
    Scattering result = { float3(0), float3(1) };
    float2 air = raySphere(origin, direction, atmosphere.z);
    float start = max(air.x, 0.0);
    float end = min(air.y, maxDistance);
    if (end <= start) return result;

    float ds = (end - start) / viewSteps;
    float2 depth = 0;
    float3 rayleigh = 0;
    float3 mie = 0;
    for (int i = 0; i < viewSteps; i++) {
        float3 p = origin + direction * (start + ds * (i + jitter));
        float2 amount = airDensity(p, atmosphere.y, density) * ds * atmosphere.y;
        depth += amount * 0.5;
        float3 light = extinction(depth) * sunTransmittance(p, sun, atmosphere, density);
        depth += amount * 0.5;
        rayleigh += amount.x * light;
        mie += amount.y * light;
    }
    float mu = dot(direction, sun);
    float rayleighPhase = 3 / (16 * M_PI_F) * (1 + mu * mu);
    float g2 = mieG * mieG;
    float miePhase = 3 / (8 * M_PI_F) * (1 - g2) * (1 + mu * mu)
        / ((2 + g2) * pow(1 + g2 - 2 * mieG * mu, 1.5));
    result.inscattered = sunIntensity * (rayleigh * rayleighScattering * rayleighPhase + mie * mieScattering * miePhase);
    result.transmittance = extinction(depth);
    return result;
}

// Interleaved gradient noise (Jimenez 2014), in 0...1.
static float pixelNoise(float2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

static float3 toneMap(float3 radiance, float exposure) {
    return 1 - exp(-radiance * exposure);
}

fragment float4 fragmentMain(Fragment in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float3 sun = u.sun.xyz;
    float light = saturate(dot(n, sun));
    if (u.elevation.w > 0.5) return float4(float3(0.75, 0.85, 1.0) * (0.25 + 0.5 * light), 1); // mesh edges
    float3 albedo = surfaceColor(in.elevation, u.elevation);
    if (u.atmosphere.x < 0.5) return float4(albedo * (0.03 + light), 1);

    // Sunlight through the air, a little skylight while the sun is up, and starlight.
    float3 up = normalize(in.world);
    float3 sunlight = sunIntensity / M_PI_F * sunTransmittance(in.world, sun, u.atmosphere, u.camera.w);
    float skylight = sunIntensity / M_PI_F * 0.06 * smoothstep(-0.15, 0.3, dot(up, sun))
        * (0.6 + 0.4 * dot(n, up));
    float3 radiance = albedo * (sunlight * light + skylight + 0.02);

    // Aerial perspective: the air between the camera and the surface.
    float3 toSurface = in.world - u.camera.xyz;
    float distance = length(toSurface);
    Scattering air = scatter(u.camera.xyz, toSurface / distance, distance, sun, u.atmosphere, 12,
                             pixelNoise(in.position.xy), u.camera.w);
    return float4(toneMap(radiance * air.transmittance + air.inscattered, u.atmosphere.w), 1);
}

// The sky: a full-screen triangle at the far plane, drawn where the terrain left the background.
struct SkyFragment {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyFragment skyVertex(uint id [[vertex_id]]) {
    float2 ndc = float2((id << 1) & 2, id & 2) * 2 - 1;
    SkyFragment out;
    out.position = float4(ndc, 0, 1);
    out.ndc = ndc;
    return out;
}

fragment float4 skyFragment(SkyFragment in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    // From the camera's basis rather than by unprojecting the near plane, which near the ground
    // lies ~1e-6 radii away, too close to subtract the camera's position precisely.
    float3 direction = normalize(u.cameraForward.xyz + in.ndc.x * u.cameraRight.w * u.cameraRight.xyz
                                 + in.ndc.y * u.cameraUp.w * u.cameraUp.xyz);
    float3 sun = u.sun.xyz;
    float ground = rayHits(u.camera.xyz, direction, 1);
    float maxDistance = ground > 0 ? ground : 1e30;
    // More samples than for the terrain: rays along the limb are long, and the sky covers less.
    Scattering air = scatter(u.camera.xyz, direction, maxDistance, sun, u.atmosphere, 32,
                             pixelNoise(in.position.xy), u.camera.w);
    // The sun's disk (about 0.5° across), dimmed by the air.
    float3 disk = ground > 0 ? 0 : float3(smoothstep(0.99996, 0.99998, dot(direction, sun)) * 40);
    return float4(toneMap(air.inscattered + disk * air.transmittance, u.atmosphere.w), 1);
}
"""
