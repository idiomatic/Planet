const std = @import("std");
const build_options = @import("build_options");

const lod = @import("lod.zig");

const Allocator = std.mem.Allocator;
const Vec = [3]f64;

pub const coarse_level: u5 = build_options.coarse_level;

const earth_radius = 6_371_000.0; // meters
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

/// Above the highest coarse vertex, in meters, for detail finer than the coarse mesh.
const floor_margin = 500.0;
/// How high the air reaches, in Earth's meters (scaled with the air's scale).
const atmosphere_height = 60_000.0;

/// The surface as the view shows it: lengths in radii of the planet as displayed.
pub const Surface = extern struct {
    /// Radii per meter of elevation, with exaggeration. Relief is relative to the planet's own
    /// radius (its Earth-scale elevations scale with it), so 100% gives Earth's proportions.
    scale: f32,
    /// Sea level, in meters.
    sea_level: f32,
    /// The camera stays at least this far from the center, in radii: above the highest point.
    floor_radius: f32,
    /// The radius of the planet the air sees, in meters: the true radius divided by the
    /// exaggeration (at least 100%), so the air's thickness keeps its proportion to the relief.
    air_planet_radius: f32,
    /// The top of the air, in radii.
    air_top: f32,
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

    /// The surface as the view shows it, with relief exaggerated `exaggeration` percent and the
    /// sea at `sea_level` percent of the elevation range.
    pub fn surface(self: *const Planet, exaggeration: f64, sea_level: f64) Surface {
        const scale: f32 = @floatCast(exaggeration / 100 / earth_radius);
        // The air's scale: the display's, but never below relief 100%, so flattening the
        // terrain (down to a smooth ball, at 0) leaves Earth's air, which also keeps the air
        // thick enough in radii for single-precision heights near radius 1.
        const air_scale: f32 = @floatCast(@max(exaggeration, 100) / 100 / earth_radius);
        const range = self.max_elevation - self.min_elevation;
        const sea: f32 = self.min_elevation + @as(f32, @floatCast(sea_level / 100)) * range;
        return .{
            .scale = scale,
            .sea_level = sea,
            .floor_radius = 1 + scale * (@max(self.max_elevation, sea) + floor_margin) + 1e-5,
            .air_planet_radius = 1 / air_scale,
            .air_top = 1 + atmosphere_height * air_scale,
        };
    }

    /// The surface in `direction`, in radii: the elevation there (or the sea, if higher), as the
    /// view shows it. The drawn mesh departs from it between vertices, by about a meter at the
    /// finest level and more at coarser ones.
    pub fn groundAt(self: *const Planet, exaggeration: f64, sea_level: f64, direction: Vec) f32 {
        const s = self.surface(exaggeration, sea_level);
        const ground: f32 = @floatCast(elevation(self.params, normalize(direction)));
        return 1 + s.scale * @max(ground, s.sea_level);
    }

    /// The coarse mesh's highest vertex, on the unit sphere (the first, on a tie).
    pub fn peak(self: *const Planet) [3]f32 {
        var best: usize = 0;
        for (self.elevations, 0..) |e, i| {
            if (e > self.elevations[best]) best = i;
        }
        return self.positions[best * 3 ..][0..3].*;
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

/// The orbit, as the sun searches see it.
pub const Orbit = struct {
    axial_tilt: f64,
    day_length: f64,
    year_length: f64,

    /// The cosine of the sun's angle from `point`'s zenith, `seconds` after epoch, with the sun's
    /// direction rounded to single precision as the renderer sees it.
    fn sunCosine(self: Orbit, point: Vec, seconds: f64) f64 {
        const s = sunFromOrbit(self.axial_tilt, self.day_length, self.year_length, seconds);
        var cosine: f64 = 0;
        for (0..3) |k| cosine += @as(f64, @as(f32, @floatCast(s[k]))) * point[k];
        return cosine;
    }

    /// Times through the first day, `samples` of them evenly spaced from 0; none without spin.
    fn sampleTimes(self: Orbit, samples: u32) SampleTimes {
        const day = earth_day * self.day_length;
        return .{ .day = day, .step = day / @as(f64, @floatFromInt(samples)) };
    }

    const SampleTimes = struct {
        day: f64,
        step: f64,
        i: u32 = 0,

        fn next(self: *SampleTimes) ?f64 {
            const t = @as(f64, @floatFromInt(self.i)) * self.step;
            if (!(t < self.day)) return null;
            self.i += 1;
            return t;
        }
    };

    /// The earliest sampled time of the first day when the sun's cosine at `point` lies in
    /// [`lo`, `hi`].
    pub fn firstSunTime(self: Orbit, point: Vec, lo: f64, hi: f64, samples: u32) ?f64 {
        var times = self.sampleTimes(samples);
        while (times.next()) |t| {
            const cosine = self.sunCosine(point, t);
            if (lo <= cosine and cosine <= hi) return t;
        }
        return null;
    }

    /// The sampled time of the first day when the sun's cosine at `point` is nearest `target`
    /// (the earliest, on a tie).
    pub fn nearestSunTime(self: Orbit, point: Vec, target: f64, samples: u32) ?f64 {
        var times = self.sampleTimes(samples);
        var best: ?f64 = null;
        var best_error: f64 = 0;
        while (times.next()) |t| {
            const err = @abs(self.sunCosine(point, t) - target);
            if (best == null or err < best_error) {
                best = t;
                best_error = err;
            }
        }
        return best;
    }
};

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
        .{ -1, phi, 0 }, .{ 1, phi, 0 }, .{ -1, -phi, 0 }, .{ 1, -phi, 0 },
        .{ 0, -1, phi }, .{ 0, 1, phi }, .{ 0, -1, -phi }, .{ 0, 1, -phi },
        .{ phi, 0, -1 }, .{ phi, 0, 1 }, .{ -phi, 0, -1 }, .{ -phi, 0, 1 },
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
/// The finest level drawn: triangles of about 100 m at Earth's radius.
pub const finest_level = 16;
pub const max_patch_level = finest_level - patch_subdivisions;
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

/// The parent's lattice point at the child's (2i, 2j), for the child (0...3) as `patchPoints`
/// orders them: (a, ab, ca), (ab, b, bc), (ca, bc, c), and (ab, bc, ca).
fn parentLattice(child: u64, i: usize, j: usize) [2]usize {
    const h = patch_n / 2;
    return switch (child) {
        0 => .{ i, j },
        1 => .{ h + i, j },
        2 => .{ i, h + j },
        else => .{ h - j, i + j },
    };
}

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
    generatePatchFrom(p, level, face, path, null, out);
}

/// Like `generatePatch`, but copies the points it shares with its parent (every other lattice
/// point: 45 of 153) from the parent's vertices, when given, instead of computing them. Shared
/// points agree bit for bit, so the result is the same, for about 30% less work.
pub fn generatePatchFrom(p: Params, level: u5, face: u5, path: u64, parent: ?[]const f32, out: []f32) void {
    const points = patchPoints(level, face, path);
    const f = patch_vertex_floats;
    for (0..patch_n + 1) |j| {
        for (0..patch_n + 1 - j) |i| {
            const v = latticeIndex(i, j);
            if (parent) |from| {
                if (level > 0 and i % 2 == 0 and j % 2 == 0) {
                    const at = parentLattice(path & 3, i / 2, j / 2);
                    @memcpy(out[v * f ..][0..8], from[latticeIndex(at[0], at[1]) * f ..][0..8]);
                    continue;
                }
            }
            writePatchVertex(p, points[v], 0, out[v * f ..]);
        }
    }

    // The parent's lattice is this one's at spacing 2, with the same triangles, so the parent
    // shows a point it shares as is, and an edge midpoint as the average of the edge's ends.
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

/// Octaves of the placeholder elevation: its finest wavelength (~60 m at Earth's radius) suits
/// the finest patches. Fixed, so a point's elevation doesn't depend on which patch asks.
const elevation_octaves = 17;

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

export fn pl_planet_surface(handle: *const Handle, exaggeration: f64, sea_level: f64) Surface {
    return planetOf(handle).surface(exaggeration, sea_level);
}

export fn pl_planet_ground_at(handle: *const Handle, exaggeration: f64, sea_level: f64, direction: *const [3]f32) f32 {
    const d: Vec = .{ direction[0], direction[1], direction[2] };
    return planetOf(handle).groundAt(exaggeration, sea_level, d);
}

export fn pl_planet_peak(handle: *const Handle, out: *[3]f32) void {
    out.* = planetOf(handle).peak();
}

export fn pl_planet_min_elevation(handle: *const Handle) f32 {
    return planetOf(handle).min_elevation;
}

export fn pl_planet_max_elevation(handle: *const Handle) f32 {
    return planetOf(handle).max_elevation;
}

export fn pl_patch_float_count() u32 {
    return lod.patch_floats;
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
export fn pl_patch_generate(
    handle: *const Handle,
    level: u32,
    face: u32,
    path: u64,
    parent: ?[*]const f32,
    out: [*]f32,
) void {
    const planet = planetOf(handle);
    const from: ?[]const f32 = if (parent) |v| v[0..lod.patch_floats] else null;
    generatePatchFrom(planet.params, @intCast(level), @intCast(face), path, from, out[0..lod.patch_floats]);
}

const LodHandle = opaque {};

fn lodOf(handle: *LodHandle) *lod.Lod {
    return @ptrCast(@alignCast(handle));
}

export fn pl_lod_create(planet: *const Handle, storage: *const lod.Storage, scale: f32, sea_level: f32) ?*LodHandle {
    const self = std.heap.smp_allocator.create(lod.Lod) catch return null;
    self.* = .init(std.heap.smp_allocator, planetOf(planet).params, storage.*, scale, sea_level);
    self.prepare() catch {
        self.deinit();
        std.heap.smp_allocator.destroy(self);
        return null;
    };
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

export fn pl_lod_set_capacity_bytes(handle: *LodHandle, bytes: u64) void {
    lodOf(handle).setCapacityBytes(bytes);
}

/// The slot, or -1 if the patch is already cached, or -2 if out of memory or storage.
export fn pl_lod_install(handle: *LodHandle, key: lod.Key, vertices: [*]const f32) i64 {
    const slot = lodOf(handle).install(key, vertices[0..lod.patch_floats]) catch return -2;
    return if (slot) |s| s else -1;
}

export fn pl_lod_select(
    handle: *LodHandle,
    view_projection: *const [16]f32,
    camera: *const [3]f32,
    pixels_per_radian: f32,
    max_in_flight: u32,
    synchronous: bool,
) bool {
    lodOf(handle).select(view_projection, camera.*, pixels_per_radian, max_in_flight, synchronous) catch return false;
    return true;
}

/// Copies the cached parent's vertices, to generate `key` from elsewhere; false if there's none.
export fn pl_lod_parent_vertices(handle: *LodHandle, key: lod.Key, out: [*]f32) bool {
    const parent = lodOf(handle).parentVertices(key) orelse return false;
    @memcpy(out[0..lod.patch_floats], parent[0..lod.patch_floats]);
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

export fn pl_lod_stats_get(handle: *LodHandle) lod.Stats {
    return lodOf(handle).stats();
}

export fn pl_sun_time_first(
    axial_tilt: f64,
    day_length: f64,
    year_length: f64,
    point: *const [3]f64,
    lo: f64,
    hi: f64,
    samples: u32,
    seconds: *f64,
) bool {
    const orbit: Orbit = .{ .axial_tilt = axial_tilt, .day_length = day_length, .year_length = year_length };
    seconds.* = orbit.firstSunTime(point.*, lo, hi, samples) orelse return false;
    return true;
}

export fn pl_sun_time_nearest(
    axial_tilt: f64,
    day_length: f64,
    year_length: f64,
    point: *const [3]f64,
    target: f64,
    samples: u32,
    seconds: *f64,
) bool {
    const orbit: Orbit = .{ .axial_tilt = axial_tilt, .day_length = day_length, .year_length = year_length };
    seconds.* = orbit.nearestSunTime(point.*, target, samples) orelse return false;
    return true;
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
    // Children 0 (a, ab, ca) and 3 (ab, bc, ca) share the edge ab–ca; near the top and at the
    // deepest level.
    try expectSiblingsAgree(3, 0b01_10);
    try expectSiblingsAgree(max_patch_level, 0x2c_3a9b);
}

fn expectSiblingsAgree(level: u5, parent_path: u64) !void {
    var a: [patch_vertices * patch_vertex_floats]f32 = undefined;
    var b: [patch_vertices * patch_vertex_floats]f32 = undefined;
    generatePatch(earth, level, 7, parent_path * 4 + 0, &a);
    generatePatch(earth, level, 7, parent_path * 4 + 3, &b);
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

test "a patch generated from its parent's vertices matches one generated alone, bit for bit" {
    var parent: [lod.patch_floats]f32 = undefined;
    var alone: [lod.patch_floats]f32 = undefined;
    var from: [lod.patch_floats]f32 = undefined;
    const cases = [_]struct { level: u5, path: u64 }{
        .{ .level = 3, .path = 0b10_01 },
        .{ .level = 3, .path = 0b00_11 },
        .{ .level = 3, .path = 0b11_10 },
        .{ .level = max_patch_level, .path = 0x2c_3a9b }, // the deepest
    };
    for (cases) |case| {
        generatePatch(earth, case.level - 1, 9, case.path, &parent);
        for (0..4) |c| {
            generatePatch(earth, case.level, 9, case.path * 4 + c, &alone);
            generatePatchFrom(earth, case.level, 9, case.path * 4 + c, &parent, &from);
            try std.testing.expectEqualSlices(u32, @ptrCast(&alone), @ptrCast(&from));
        }
    }
}

test "the exact elevation gradient matches finite differences" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..200) |_| {
        const point = normalize(.{ random.float(f64) - 0.5, random.float(f64) - 0.5, random.float(f64) - 0.5 });
        const exact = elevationWithGradient(earth, point).gradient;
        const h = 1e-9; // well under the finest wavelength (~1e-5 radii)
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

test "the surface scales with relief, but the air not below Earth's" {
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    const real = planet.surface(100, 55);
    try std.testing.expectEqual(@as(f32, 1.0 / earth_radius), real.scale);
    try std.testing.expectEqual(@as(f32, earth_radius), real.air_planet_radius);
    try std.testing.expect(real.floor_radius > 1 + real.scale * planet.max_elevation);
    const flat = planet.surface(0, 55);
    try std.testing.expectEqual(0, flat.scale);
    try std.testing.expectEqual(real.air_planet_radius, flat.air_planet_radius);
    try std.testing.expectEqual(real.air_top, flat.air_top);
    const tall = planet.surface(5000, 55);
    try std.testing.expectApproxEqRel(real.air_planet_radius / 50, tall.air_planet_radius, 1e-6);
    try std.testing.expectEqual(planet.min_elevation, planet.surface(100, 0).sea_level);
    try std.testing.expectApproxEqRel(planet.max_elevation, planet.surface(100, 100).sea_level, 1e-6);
}

test "the ground follows the terrain and the sea, below the global floor" {
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    const s = planet.surface(100, 55);
    var land = false;
    var sea = false;
    for (0..64) |i| {
        const angle = @as(f64, @floatFromInt(i)) * 0.4;
        const direction = normalize(.{ @cos(angle), @sin(angle * 0.7), @sin(angle) });
        const ground = planet.groundAt(100, 55, direction);
        const e: f32 = @floatCast(elevation(earth, direction));
        try std.testing.expectEqual(1 + s.scale * @max(e, s.sea_level), ground);
        try std.testing.expect(ground < s.floor_radius);
        land = land or e > s.sea_level;
        sea = sea or e < s.sea_level;
    }
    try std.testing.expect(land and sea);
    // A smooth ball's ground is radius 1.
    try std.testing.expectEqual(1, planet.groundAt(0, 55, .{ 0, 0, 1 }));
}

test "the peak is the highest coarse vertex" {
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    const peak = planet.peak();
    for (planet.elevations, 0..) |e, i| {
        if (e == planet.max_elevation) {
            try std.testing.expectEqual(planet.positions[i * 3 ..][0..3].*, peak);
            break;
        }
    }
}

test "sun times: the first is earliest in range, the nearest is nearest, and no spin has none" {
    const orbit: Orbit = .{ .axial_tilt = 23.44, .day_length = 1, .year_length = 1 };
    const point = normalize(.{ 1, 0.2, 0.3 });
    const first = orbit.firstSunTime(point, 0.25, 0.4, 288).?;
    const cosine = orbit.sunCosine(point, first);
    try std.testing.expect(0.25 <= cosine and cosine <= 0.4);
    var t: f64 = 0;
    while (t < first) : (t += earth_day / 288) {
        const c = orbit.sunCosine(point, t);
        try std.testing.expect(!(0.25 <= c and c <= 0.4));
    }
    const target = @cos(std.math.degreesToRadians(50.0));
    const nearest = orbit.nearestSunTime(point, target, 1440).?;
    const step = earth_day / 1440;
    const err = @abs(orbit.sunCosine(point, nearest) - target);
    try std.testing.expect(err <= @abs(orbit.sunCosine(point, nearest + step) - target));
    try std.testing.expect(err <= @abs(orbit.sunCosine(point, nearest - step) - target));
    const still: Orbit = .{ .axial_tilt = 23.44, .day_length = 0, .year_length = 1 };
    try std.testing.expectEqual(null, still.firstSunTime(point, 0.25, 0.4, 288));
    try std.testing.expectEqual(null, still.nearestSunTime(point, target, 1440));
}

test "seeds from text" {
    try std.testing.expectEqual(@as(u64, 9000), seedFromString("9000"));
    try std.testing.expectEqual(seedFromString("Mihira"), seedFromString("Mihira"));
    try std.testing.expect(seedFromString("hal") != seedFromString("art"));
}
