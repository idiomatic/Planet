const std = @import("std");
const build_options = @import("build_options");

const lod = @import("lod.zig");

const Allocator = std.mem.Allocator;
const Vec = [3]f64;

pub const coarse_level: u5 = build_options.coarse_level;

const earth_day = 86_400.0; // seconds
const earth_year = 365.25 * earth_day;
const elevation_amplitude = 8_000.0; // meters

/// Exactly the inputs that generate a planet.
pub const Params = extern struct {
    seed: u64,
    region_scale: f64,

    fn sanitized(self: Params) Params {
        var p = self;
        p.region_scale = @max(p.region_scale, 1.0);
        return p;
    }
};

pub const Planet = struct {
    arena: std.heap.ArenaAllocator,
    params: Params,
    positions: []f32,
    elevations: []f32,
    addresses: []u64,
    indices: []u32,
    min_elevation: f32,
    max_elevation: f32,

    pub fn create(backing: Allocator, params: Params) !*Planet {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const gpa = arena.allocator();
        const p = params.sanitized();

        var mesh: Mesh = .{ .gpa = gpa, .level = coarse_level };
        try mesh.build();
        const count = mesh.points.items.len;

        const positions = try gpa.alloc(f32, count * 3);
        const elevations = try gpa.alloc(f32, count);
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        for (mesh.points.items, 0..) |point, i| {
            for (0..3) |k| positions[i * 3 + k] = @floatCast(point[k]);
            const e: f32 = @floatCast(elevation(p, point));
            elevations[i] = e;
            lo = @min(lo, e);
            hi = @max(hi, e);
        }

        const planet = try gpa.create(Planet);
        planet.* = .{
            .arena = undefined,
            .params = p,
            .positions = positions,
            .elevations = elevations,
            .addresses = mesh.addresses.items,
            .indices = mesh.indices.items,
            .min_elevation = lo,
            .max_elevation = hi,
        };
        planet.arena = arena;
        return planet;
    }

    pub fn destroy(self: *Planet) void {
        var arena = self.arena;
        arena.deinit();
    }

};

/// The unit vector toward the sun in the planet's frame, `seconds` after epoch: a pure function
/// of the orbit, so tilt, day length, and year length can change while time runs.
pub fn sunFromOrbit(axial_tilt: f64, day_length: f64, year_length: f64, seconds: f64) Vec {
    const tau = 2.0 * std.math.pi;
    // A length of 0 means no orbit (no seasons) or no spin (the sun holds still in the sky).
    const orbit = if (year_length > 0) tau * seconds / (earth_year * year_length) else 0;
    const spin = if (day_length > 0) tau * seconds / (earth_day * day_length) else 0;
    const tilt = std.math.degreesToRadians(axial_tilt);
    // Ecliptic: the orbit lies in x–z, with the planet's axis tilted toward +z.
    const s: Vec = .{ @cos(orbit), 0, @sin(orbit) };
    const untilted: Vec = .{ s[0], s[2] * @sin(tilt), s[2] * @cos(tilt) };
    return .{
        untilted[0] * @cos(spin) - untilted[2] * @sin(spin),
        untilted[1],
        untilted[0] * @sin(spin) + untilted[2] * @cos(spin),
    };
}

/// Icosphere whose vertices carry their lowest subdivision-path address.
const Mesh = struct {
    gpa: Allocator,
    level: u5,
    points: std.ArrayList(Vec) = .empty,
    addresses: std.ArrayList(u64) = .empty,
    indices: std.ArrayList(u32) = .empty,
    midpoints: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    const phi = (1.0 + @sqrt(5.0)) / 2.0;
    const base_points = [12]Vec{
        .{ -1, phi, 0 },  .{ 1, phi, 0 },  .{ -1, -phi, 0 }, .{ 1, -phi, 0 },
        .{ 0, -1, phi },  .{ 0, 1, phi },  .{ 0, -1, -phi }, .{ 0, 1, -phi },
        .{ phi, 0, -1 },  .{ phi, 0, 1 },  .{ -phi, 0, -1 }, .{ -phi, 0, 1 },
    };
    const base_faces = [20][3]u32{
        .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
        .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
        .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
        .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
    };

    fn build(self: *Mesh) !void {
        for (base_points) |p| try self.addPoint(normalize(p));
        for (base_faces, 0..) |f, face| try self.subdivide(face, 0, f[0], f[1], f[2]);
    }

    fn addPoint(self: *Mesh, p: Vec) !void {
        try self.points.append(self.gpa, p);
        try self.addresses.append(self.gpa, std.math.maxInt(u64));
    }

    fn midpoint(self: *Mesh, a: u32, b: u32) !u32 {
        const key = (@as(u64, @min(a, b)) << 32) | @max(a, b);
        const entry = try self.midpoints.getOrPut(self.gpa, key);
        if (entry.found_existing) return entry.value_ptr.*;
        const pa = self.points.items[a];
        const pb = self.points.items[b];
        const index: u32 = @intCast(self.points.items.len);
        try self.addPoint(midpointOf(pa, pb));
        entry.value_ptr.* = index;
        return index;
    }

    /// `path` is the base face followed by one child index (0...3) per level.
    fn subdivide(self: *Mesh, path: u64, depth: u5, a: u32, b: u32, c: u32) !void {
        if (depth == self.level) {
            const corners = [3]u32{ a, b, c };
            try self.indices.appendSlice(self.gpa, &corners);
            for (corners, 0..) |v, corner| {
                const address = (path << 2) | corner;
                self.addresses.items[v] = @min(self.addresses.items[v], address);
            }
            return;
        }
        const ab = try self.midpoint(a, b);
        const bc = try self.midpoint(b, c);
        const ca = try self.midpoint(c, a);
        try self.subdivide(path * 4 + 0, depth + 1, a, ab, ca);
        try self.subdivide(path * 4 + 1, depth + 1, ab, b, bc);
        try self.subdivide(path * 4 + 2, depth + 1, ca, bc, c);
        try self.subdivide(path * 4 + 3, depth + 1, ab, bc, ca);
    }
};

/// A patch is a triangle of the subdivided icosahedron, named by level, base face, and path
/// (one child index, 0...3, per level), drawn as `patch_subdivisions` more levels of triangles.
pub const patch_subdivisions = 4;
pub const max_patch_level = 12 - patch_subdivisions;
const patch_n = 1 << patch_subdivisions; // lattice intervals per patch edge
const patch_surface_vertices = (patch_n + 1) * (patch_n + 2) / 2;
const patch_skirt_vertices = 3 * (patch_n + 1);
pub const patch_vertices = patch_surface_vertices + patch_skirt_vertices;
pub const patch_surface_indices = 3 * patch_n * patch_n;
pub const patch_indices = patch_surface_indices + 3 * 6 * patch_n;
/// Floats per patch vertex: direction (3), elevation in meters, tangential elevation gradient
/// in meters per radian (3), skirt (0 on the surface, 1 on the skirt's lower edge), and the
/// elevation (1) and gradient (3) the parent patch shows there, for blending between levels.
pub const patch_vertex_floats = 12;

/// Lattice point (i, j), with i + j ≤ n, at corner a + i/n·(b − a) + j/n·(c − a).
fn latticeIndex(i: usize, j: usize) usize {
    return j * (patch_n + 1) - (j * j - j) / 2 + i;
}

/// The patch's surface positions on the unit sphere, by the same midpoint normalizations as the
/// coarse mesh, so vertices shared with it or with neighboring patches agree bit for bit.
fn patchPoints(level: u5, face: u5, path: u64) [patch_surface_vertices]Vec {
    const f = Mesh.base_faces[face];
    var a = normalize(Mesh.base_points[f[0]]);
    var b = normalize(Mesh.base_points[f[1]]);
    var c = normalize(Mesh.base_points[f[2]]);
    var depth: u5 = 0;
    while (depth < level) : (depth += 1) {
        const child = (path >> (@as(u6, level - 1 - depth) * 2)) & 3;
        const ab = midpointOf(a, b);
        const bc = midpointOf(b, c);
        const ca = midpointOf(c, a);
        // The same child order as Mesh.subdivide.
        const next: [3]Vec = switch (child) {
            0 => .{ a, ab, ca },
            1 => .{ ab, b, bc },
            2 => .{ ca, bc, c },
            else => .{ ab, bc, ca },
        };
        a = next[0];
        b = next[1];
        c = next[2];
    }

    var points: [patch_surface_vertices]Vec = undefined;
    points[latticeIndex(0, 0)] = a;
    points[latticeIndex(patch_n, 0)] = b;
    points[latticeIndex(0, patch_n)] = c;
    var step: usize = patch_n / 2;
    while (step >= 1) : (step /= 2) {
        var j: usize = 0;
        while (j <= patch_n) : (j += step) {
            var i: usize = 0;
            while (i + j <= patch_n) : (i += step) {
                const ends = edgeEnds(i, j, step) orelse continue;
                points[latticeIndex(i, j)] = midpointOf(points[ends[0]], points[ends[1]]);
            }
        }
    }
    return points;
}

/// For a lattice point that's the midpoint of an edge at spacing 2·`step`, that edge's ends.
fn edgeEnds(i: usize, j: usize, step: usize) ?[2]usize {
    const odd_i = (i / step) % 2 == 1;
    const odd_j = (j / step) % 2 == 1;
    if (odd_i and odd_j) return .{ latticeIndex(i - step, j + step), latticeIndex(i + step, j - step) };
    if (odd_i) return .{ latticeIndex(i - step, j), latticeIndex(i + step, j) };
    if (odd_j) return .{ latticeIndex(i, j - step), latticeIndex(i, j + step) };
    return null;
}

/// Writes a patch's vertices (`patch_vertices` × `patch_vertex_floats`): the surface lattice,
/// then each edge again as the skirt's lower edge. Pure in (params, level, face, path).
pub fn generatePatch(p: Params, level: u5, face: u5, path: u64, out: []f32) void {
    const points = patchPoints(level, face, path);
    for (points, 0..) |point, v| writePatchVertex(p, point, 0, out[v * patch_vertex_floats ..]);

    // The parent's lattice is this one's at spacing 2, with the same triangles, so the parent
    // shows a point it shares as is, and an edge midpoint as the average of the edge's ends.
    const f = patch_vertex_floats;
    for (0..patch_surface_vertices) |v| @memcpy(out[v * f + 8 ..][0..4], out[v * f + 3 ..][0..4]);
    for (0..patch_n + 1) |j| {
        for (0..patch_n + 1 - j) |i| {
            const ends = edgeEnds(i, j, 1) orelse continue;
            const v = latticeIndex(i, j);
            for (0..4) |k| out[v * f + 8 + k] = (out[ends[0] * f + 3 + k] + out[ends[1] * f + 3 + k]) / 2;
        }
    }

    for (patchEdges(), 0..) |surface, s| {
        const from = out[surface * patch_vertex_floats ..][0..patch_vertex_floats];
        const to = out[(patch_surface_vertices + s) * patch_vertex_floats ..][0..patch_vertex_floats];
        to.* = from.*;
        to[7] = 1;
    }
}

fn writePatchVertex(p: Params, point: Vec, skirt: f32, out: []f32) void {
    // The exact gradient, a function of the point alone, so a vertex shades alike in every
    // patch that has it; only its tangential part matters on the sphere.
    const e = elevationWithGradient(p, point);
    const radial = e.gradient[0] * point[0] + e.gradient[1] * point[1] + e.gradient[2] * point[2];
    for (0..3) |k| {
        out[k] = @floatCast(point[k]);
        out[4 + k] = @floatCast(e.gradient[k] - radial * point[k]);
    }
    out[3] = @floatCast(e.value);
    out[7] = skirt;
}

/// Surface vertex indices along the three edges, in order: a→b, b→c, c→a.
fn patchEdges() [patch_skirt_vertices]usize {
    var edges: [patch_skirt_vertices]usize = undefined;
    for (0..patch_n + 1) |k| {
        edges[k] = latticeIndex(k, 0);
        edges[patch_n + 1 + k] = latticeIndex(patch_n - k, k);
        edges[2 * (patch_n + 1) + k] = latticeIndex(0, patch_n - k);
    }
    return edges;
}

/// Triangle indices shared by every patch: the surface first (`patch_surface_indices`), then
/// the skirts.
pub fn patchIndexPattern(out: []u32) void {
    var n: usize = 0;
    for (0..patch_n) |j| {
        for (0..patch_n - j) |i| {
            for ([3]usize{ latticeIndex(i, j), latticeIndex(i + 1, j), latticeIndex(i, j + 1) }) |v| {
                out[n] = @intCast(v);
                n += 1;
            }
            if (i + j + 2 <= patch_n) {
                for ([3]usize{ latticeIndex(i + 1, j), latticeIndex(i + 1, j + 1), latticeIndex(i, j + 1) }) |v| {
                    out[n] = @intCast(v);
                    n += 1;
                }
            }
        }
    }
    const edges = patchEdges();
    for (0..3) |e| {
        for (0..patch_n) |k| {
            const s = e * (patch_n + 1) + k;
            const top0 = edges[s];
            const top1 = edges[s + 1];
            const low0 = patch_surface_vertices + s;
            const low1 = low0 + 1;
            for ([6]usize{ top0, top1, low1, top0, low1, low0 }) |v| {
                out[n] = @intCast(v);
                n += 1;
            }
        }
    }
}

fn midpointOf(a: Vec, b: Vec) Vec {
    return normalize(.{ a[0] + b[0], a[1] + b[1], a[2] + b[2] });
}

fn normalize(v: Vec) Vec {
    const n = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / n, v[1] / n, v[2] / n };
}

fn cross(a: Vec, b: Vec) Vec {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// Octaves of the placeholder elevation: its finest wavelength (~1 km at Earth's radius) suits
/// the finest patches. Fixed, so a point's elevation doesn't depend on which patch asks.
const elevation_octaves = 13;

/// A noise value and its gradient with respect to the sample point.
const Sample = struct { value: f64, gradient: Vec };

/// Placeholder for tectonics: warped fractal noise, in meters.
fn elevation(p: Params, point: Vec) f64 {
    return elevationWithGradient(p, point).value;
}

/// The elevation and its 3D gradient in meters per radius, by the chain rule through the warp:
/// E(x) = A·m(q + w(q)), q = f·x, so ∇E = A·f·(I + J_w)ᵀ·∇m.
fn elevationWithGradient(p: Params, point: Vec) Sample {
    const frequency = 1.2 / p.region_scale;
    const q: Vec = .{ point[0] * frequency, point[1] * frequency, point[2] * frequency };
    const warp = [3]Sample{
        fbm(p.seed +% 101, q, 4),
        fbm(p.seed +% 202, q, 4),
        fbm(p.seed +% 303, q, 4),
    };
    const main = fbm(p.seed, .{ q[0] + warp[0].value, q[1] + warp[1].value, q[2] + warp[2].value }, elevation_octaves);
    var gradient: Vec = undefined;
    for (0..3) |j| {
        var g = main.gradient[j];
        for (0..3) |k| g += main.gradient[k] * warp[k].gradient[j];
        gradient[j] = g * elevation_amplitude * frequency;
    }
    return .{ .value = main.value * elevation_amplitude, .gradient = gradient };
}

fn fbm(seed: u64, p: Vec, octaves: u32) Sample {
    var sum: f64 = 0;
    var gradient: Vec = .{ 0, 0, 0 };
    var norm: f64 = 0;
    var amplitude: f64 = 1;
    var frequency: f64 = 1;
    for (0..octaves) |octave| {
        const s = seed +% @as(u64, octave) *% 0x9E3779B97F4A7C15;
        const n = valueNoise(s, .{ p[0] * frequency, p[1] * frequency, p[2] * frequency });
        sum += amplitude * n.value;
        for (0..3) |k| gradient[k] += amplitude * frequency * n.gradient[k];
        norm += amplitude;
        amplitude *= 0.5;
        frequency *= 2.03;
    }
    return .{ .value = sum / norm, .gradient = .{ gradient[0] / norm, gradient[1] / norm, gradient[2] / norm } };
}

fn valueNoise(seed: u64, p: Vec) Sample {
    const f: Vec = .{ @floor(p[0]), @floor(p[1]), @floor(p[2]) };
    const cell = [3]i64{ @intFromFloat(f[0]), @intFromFloat(f[1]), @intFromFloat(f[2]) };
    const r: Vec = .{ p[0] - f[0], p[1] - f[1], p[2] - f[2] };
    const t: Vec = .{ fade(r[0]), fade(r[1]), fade(r[2]) };
    var c: [8]f64 = undefined;
    for (&c, 0..) |*corner, i| {
        corner.* = lattice(seed, .{
            cell[0] + @as(i64, @intCast(i & 1)),
            cell[1] + @as(i64, @intCast((i >> 1) & 1)),
            cell[2] + @as(i64, @intCast((i >> 2) & 1)),
        });
    }
    const x0 = lerp(c[0], c[1], t[0]);
    const x1 = lerp(c[2], c[3], t[0]);
    const x2 = lerp(c[4], c[5], t[0]);
    const x3 = lerp(c[6], c[7], t[0]);
    const y0 = lerp(x0, x1, t[1]);
    const y1 = lerp(x2, x3, t[1]);
    // Derivatives of the same trilinear blend, through the fade curve.
    const dx = lerp(lerp(c[1] - c[0], c[3] - c[2], t[1]), lerp(c[5] - c[4], c[7] - c[6], t[1]), t[2]);
    const dy = lerp(x1 - x0, x3 - x2, t[2]);
    const dz = y1 - y0;
    return .{
        .value = lerp(y0, y1, t[2]),
        .gradient = .{ dx * fadeSlope(r[0]), dy * fadeSlope(r[1]), dz * fadeSlope(r[2]) },
    };
}

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn fadeSlope(t: f64) f64 {
    return 30 * t * t * (t * (t - 2) + 1);
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

/// Uniform value in [-1, 1] for a lattice point.
fn lattice(seed: u64, cell: [3]i64) f64 {
    var h = mix(seed);
    for (cell) |c| h = mix(h ^ @as(u64, @bitCast(c)));
    return @as(f64, @floatFromInt(h >> 11)) / (1 << 52) - 1;
}

/// SplitMix64 finalizer.
fn mix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// A decimal seed is used as is; any other text is hashed with FNV-1a.
pub fn seedFromString(text: []const u8) u64 {
    return std.fmt.parseInt(u64, text, 10) catch {
        var h: u64 = 0xcbf29ce484222325;
        for (text) |byte| h = (h ^ byte) *% 0x100000001b3;
        return h;
    };
}

// C ABI

const Handle = opaque {};

fn planetOf(handle: *const Handle) *const Planet {
    return @ptrCast(@alignCast(handle));
}

export fn pl_seed_from_string(text: [*]const u8, length: usize) u64 {
    return seedFromString(text[0..length]);
}

export fn pl_planet_create(params: *const Params) ?*Handle {
    const planet = Planet.create(std.heap.page_allocator, params.*) catch return null;
    return @ptrCast(planet);
}

export fn pl_planet_destroy(handle: ?*Handle) void {
    const planet: *Planet = @ptrCast(@alignCast(handle orelse return));
    planet.destroy();
}

export fn pl_planet_vertex_count(handle: *const Handle) u32 {
    return @intCast(planetOf(handle).elevations.len);
}

export fn pl_planet_positions(handle: *const Handle) [*]const f32 {
    return planetOf(handle).positions.ptr;
}

export fn pl_planet_elevations(handle: *const Handle) [*]const f32 {
    return planetOf(handle).elevations.ptr;
}

export fn pl_planet_addresses(handle: *const Handle) [*]const u64 {
    return planetOf(handle).addresses.ptr;
}

export fn pl_planet_index_count(handle: *const Handle) u32 {
    return @intCast(planetOf(handle).indices.len);
}

export fn pl_planet_indices(handle: *const Handle) [*]const u32 {
    return planetOf(handle).indices.ptr;
}

export fn pl_planet_min_elevation(handle: *const Handle) f32 {
    return planetOf(handle).min_elevation;
}

export fn pl_planet_max_elevation(handle: *const Handle) f32 {
    return planetOf(handle).max_elevation;
}

export fn pl_patch_max_level() u32 {
    return max_patch_level;
}

export fn pl_patch_vertex_count() u32 {
    return patch_vertices;
}

export fn pl_patch_surface_index_count() u32 {
    return patch_surface_indices;
}

export fn pl_patch_index_count() u32 {
    return patch_indices;
}

export fn pl_patch_indices(out: [*]u32) void {
    patchIndexPattern(out[0..patch_indices]);
}

/// Thread-safe: reads only the planet's immutable parameters.
export fn pl_patch_generate(handle: *const Handle, level: u32, face: u32, path: u64, out: [*]f32) void {
    const planet = planetOf(handle);
    generatePatch(planet.params, @intCast(level), @intCast(face), path, out[0 .. patch_vertices * patch_vertex_floats]);
}

const LodHandle = opaque {};

fn lodOf(handle: *LodHandle) *lod.Lod {
    return @ptrCast(@alignCast(handle));
}

export fn pl_lod_create(scale: f32, sea_level: f32) ?*LodHandle {
    const self = std.heap.smp_allocator.create(lod.Lod) catch return null;
    self.* = .init(std.heap.smp_allocator, scale, sea_level);
    return @ptrCast(self);
}

export fn pl_lod_destroy(handle: ?*LodHandle) void {
    const self = lodOf(handle orelse return);
    self.deinit();
    std.heap.smp_allocator.destroy(self);
}

export fn pl_lod_set_surface(handle: *LodHandle, scale: f32, sea_level: f32) void {
    lodOf(handle).setSurface(scale, sea_level);
}

export fn pl_lod_set_detail(handle: *LodHandle, target_pixels: f32) void {
    lodOf(handle).target_pixels = target_pixels;
}

export fn pl_lod_set_capacity(handle: *LodHandle, patches: u32) void {
    lodOf(handle).capacity = patches;
}

/// The slot, or -1 if the patch is already cached, or -2 if out of memory.
export fn pl_lod_install(handle: *LodHandle, key: lod.Key, vertices: [*]const f32) i64 {
    const slot = lodOf(handle).install(key, vertices) catch return -2;
    return if (slot) |s| s else -1;
}

export fn pl_lod_cancel(handle: *LodHandle, key: lod.Key) void {
    lodOf(handle).cancel(key);
}

export fn pl_lod_select(
    handle: *LodHandle,
    view_projection: *const [16]f32,
    camera: *const [3]f32,
    pixels_per_radian: f32,
    max_in_flight: u32,
) bool {
    lodOf(handle).select(view_projection, camera.*, pixels_per_radian, max_in_flight) catch return false;
    return true;
}

export fn pl_lod_draws(handle: *LodHandle, count: *u32) [*]const lod.Draw {
    const items = lodOf(handle).draws.items;
    count.* = @intCast(items.len);
    return items.ptr;
}

export fn pl_lod_requests(handle: *LodHandle, count: *u32) [*]const lod.Key {
    const items = lodOf(handle).requests.items;
    count.* = @intCast(items.len);
    return items.ptr;
}

export fn pl_lod_evicted(handle: *LodHandle, count: *u32) [*]const u32 {
    const items = lodOf(handle).evicted.items;
    count.* = @intCast(items.len);
    return items.ptr;
}

export fn pl_lod_stats_get(handle: *LodHandle) lod.Stats {
    return lodOf(handle).stats();
}

export fn pl_sun_direction(axial_tilt: f64, day_length: f64, year_length: f64, seconds: f64, out: *[3]f32) void {
    const s = sunFromOrbit(axial_tilt, day_length, year_length, seconds);
    for (0..3) |k| out[k] = @floatCast(s[k]);
}

// Tests

test {
    _ = lod;
}

pub const earth: Params = .{
    .seed = 42,
    .region_scale = 1,
};

test "icosphere has the expected counts" {
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    const faces = 20 * std.math.pow(usize, 4, coarse_level);
    try std.testing.expectEqual(faces / 2 + 2, planet.elevations.len);
    try std.testing.expectEqual(faces * 3, planet.indices.len);
}

test "vertex addresses are assigned and unique" {
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (planet.addresses) |address| {
        try std.testing.expect(address != std.math.maxInt(u64));
        try std.testing.expect(!(try seen.getOrPut(std.testing.allocator, address)).found_existing);
    }
}

test "same seed and parameters produce the same planet" {
    const a = try Planet.create(std.testing.allocator, earth);
    defer a.destroy();
    const b = try Planet.create(std.testing.allocator, earth);
    defer b.destroy();
    try std.testing.expectEqualSlices(f32, a.elevations, b.elevations);
    var other = earth;
    other.seed = 43;
    const c = try Planet.create(std.testing.allocator, other);
    defer c.destroy();
    try std.testing.expect(!std.mem.eql(f32, a.elevations, c.elevations));
}

test "sun reaches the tropic at the solstice" {
    const s = sunFromOrbit(23.44, 1, 1, earth_year / 4);
    try std.testing.expectApproxEqAbs(@sin(std.math.degreesToRadians(23.44)), s[1], 1e-9);
}

fn patchPosition(out: []const f32, v: usize) [3]f32 {
    return out[v * patch_vertex_floats ..][0..3].*;
}

test "patches at the coarse level reproduce the coarse mesh's vertices exactly" {
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    var coarse: std.AutoHashMapUnmanaged([3]u32, void) = .empty;
    defer coarse.deinit(std.testing.allocator);
    for (0..planet.elevations.len) |v| {
        try coarse.put(std.testing.allocator, @bitCast(planet.positions[v * 3 ..][0..3].*), {});
    }
    const level = coarse_level - patch_subdivisions;
    var out: [patch_vertices * patch_vertex_floats]f32 = undefined;
    for (0..20) |face| {
        for ([_]u64{ 0, 5, (1 << (2 * @as(u6, level))) - 1 }) |path| {
            generatePatch(earth, level, @intCast(face), path, &out);
            for (0..patch_surface_vertices) |v| {
                try std.testing.expect(coarse.contains(@bitCast(patchPosition(&out, v))));
            }
        }
    }
}

test "sibling patches agree bit for bit along shared edges" {
    var a: [patch_vertices * patch_vertex_floats]f32 = undefined;
    var b: [patch_vertices * patch_vertex_floats]f32 = undefined;
    // Children 0 (a, ab, ca) and 3 (ab, bc, ca) share the edge ab–ca.
    generatePatch(earth, 3, 7, 0b01_10_00, &a);
    generatePatch(earth, 3, 7, 0b01_10_11, &b);
    var shared: usize = 0;
    for (0..patch_surface_vertices) |u| {
        for (0..patch_surface_vertices) |v| {
            const pa = patchPosition(&a, u);
            if (!std.mem.eql(f32, &pa, &patchPosition(&b, v))) continue;
            shared += 1;
            try std.testing.expectEqualSlices(
                f32,
                a[u * patch_vertex_floats ..][0..patch_vertex_floats],
                b[v * patch_vertex_floats ..][0..patch_vertex_floats],
            );
        }
    }
    try std.testing.expectEqual(@as(usize, patch_n + 1), shared);
}

test "a child's parent values match the parent wherever they share a point" {
    const f = patch_vertex_floats;
    var parent: [patch_vertices * f]f32 = undefined;
    var child: [patch_vertices * f]f32 = undefined;
    generatePatch(earth, 2, 4, 0b10_01, &parent);
    for (0..4) |c| {
        generatePatch(earth, 3, 4, 0b10_01 * 4 + c, &child);
        var shared: usize = 0;
        for (0..patch_surface_vertices) |v| {
            for (0..patch_surface_vertices) |u| {
                if (!std.mem.eql(f32, &patchPosition(&child, v), &patchPosition(&parent, u))) continue;
                shared += 1;
                try std.testing.expectEqualSlices(f32, parent[u * f + 3 ..][0..4], child[v * f + 8 ..][0..4]);
            }
        }
        // The child's even lattice points: (n/2 + 1)(n/2 + 2)/2 of them.
        try std.testing.expectEqual(@as(usize, (patch_n / 2 + 1) * (patch_n / 2 + 2) / 2), shared);
    }
}

test "the exact elevation gradient matches finite differences" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..200) |_| {
        const point = normalize(.{ random.float(f64) - 0.5, random.float(f64) - 0.5, random.float(f64) - 0.5 });
        const exact = elevationWithGradient(earth, point).gradient;
        const h = 1e-7;
        for (0..3) |k| {
            var plus = point;
            var minus = point;
            plus[k] += h;
            minus[k] -= h;
            const numeric = (elevation(earth, plus) - elevation(earth, minus)) / (2 * h);
            try std.testing.expectApproxEqAbs(numeric, exact[k], 1e-4 * (@abs(numeric) + 1e4));
        }
    }
}

test "patch indices stay in range" {
    var indices: [patch_indices]u32 = undefined;
    patchIndexPattern(&indices);
    for (indices) |i| try std.testing.expect(i < patch_vertices);
}

test "a day or year length of 0 stops the spin or the orbit" {
    const still = sunFromOrbit(23.44, 0, 0, 1e7);
    const start = sunFromOrbit(23.44, 0, 0, 0);
    for (0..3) |k| try std.testing.expectEqual(start[k], still[k]);
}

test "seeds from text" {
    try std.testing.expectEqual(@as(u64, 9000), seedFromString("9000"));
    try std.testing.expectEqual(seedFromString("Mihira"), seedFromString("Mihira"));
    try std.testing.expect(seedFromString("hal") != seedFromString("art"));
}
