const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Vec = [3]f64;

pub const coarse_level: u5 = build_options.coarse_level;

const earth_radius = 6_371_000.0; // meters
const earth_day = 86_400.0; // seconds
const earth_year = 365.25 * earth_day;
const elevation_amplitude = 8_000.0; // meters

pub const Params = extern struct {
    seed: u64,
    radius_scale: f64,
    region_scale: f64,
    sea_level: f64,
    axial_tilt: f64,
    day_length: f64,
    year_length: f64,

    fn sanitized(self: Params) Params {
        var p = self;
        p.radius_scale = @max(p.radius_scale, 0.01);
        p.region_scale = @max(p.region_scale, 1.0);
        p.sea_level = std.math.clamp(p.sea_level, 0.0, 1.0);
        p.axial_tilt = std.math.clamp(p.axial_tilt, -180.0, 180.0);
        p.day_length = @max(p.day_length, 0.001);
        p.year_length = @max(p.year_length, 0.001);
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
    sea_level: f32,
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
            .sea_level = lo + @as(f32, @floatCast(p.sea_level)) * (hi - lo),
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

    pub fn radius(self: *const Planet) f64 {
        return earth_radius * self.params.radius_scale;
    }

    pub fn sunDirection(self: *const Planet, seconds: f64) Vec {
        const tau = 2.0 * std.math.pi;
        const orbit = tau * seconds / (earth_year * self.params.year_length);
        const spin = tau * seconds / (earth_day * self.params.day_length);
        const tilt = std.math.degreesToRadians(self.params.axial_tilt);
        // Ecliptic: the orbit lies in x–z, with the planet's axis tilted toward +z.
        const s: Vec = .{ @cos(orbit), 0, @sin(orbit) };
        const untilted: Vec = .{ s[0], s[2] * @sin(tilt), s[2] * @cos(tilt) };
        return .{
            untilted[0] * @cos(spin) - untilted[2] * @sin(spin),
            untilted[1],
            untilted[0] * @sin(spin) + untilted[2] * @cos(spin),
        };
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
        try self.addPoint(normalize(.{ pa[0] + pb[0], pa[1] + pb[1], pa[2] + pb[2] }));
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

fn normalize(v: Vec) Vec {
    const n = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / n, v[1] / n, v[2] / n };
}

/// Placeholder for tectonics: warped fractal noise, in meters.
fn elevation(p: Params, point: Vec) f64 {
    const frequency = 1.2 / p.region_scale;
    const q: Vec = .{ point[0] * frequency, point[1] * frequency, point[2] * frequency };
    const warp: Vec = .{
        fbm(p.seed +% 101, q, 4),
        fbm(p.seed +% 202, q, 4),
        fbm(p.seed +% 303, q, 4),
    };
    const e = fbm(p.seed, .{ q[0] + warp[0], q[1] + warp[1], q[2] + warp[2] }, 7);
    return e * elevation_amplitude;
}

fn fbm(seed: u64, p: Vec, octaves: u32) f64 {
    var sum: f64 = 0;
    var norm: f64 = 0;
    var amplitude: f64 = 1;
    var frequency: f64 = 1;
    for (0..octaves) |octave| {
        const s = seed +% @as(u64, octave) *% 0x9E3779B97F4A7C15;
        sum += amplitude * valueNoise(s, .{ p[0] * frequency, p[1] * frequency, p[2] * frequency });
        norm += amplitude;
        amplitude *= 0.5;
        frequency *= 2.03;
    }
    return sum / norm;
}

fn valueNoise(seed: u64, p: Vec) f64 {
    const f: Vec = .{ @floor(p[0]), @floor(p[1]), @floor(p[2]) };
    const cell = [3]i64{ @intFromFloat(f[0]), @intFromFloat(f[1]), @intFromFloat(f[2]) };
    const t: Vec = .{ fade(p[0] - f[0]), fade(p[1] - f[1]), fade(p[2] - f[2]) };
    var corners: [8]f64 = undefined;
    for (&corners, 0..) |*corner, i| {
        corner.* = lattice(seed, .{
            cell[0] + @as(i64, @intCast(i & 1)),
            cell[1] + @as(i64, @intCast((i >> 1) & 1)),
            cell[2] + @as(i64, @intCast((i >> 2) & 1)),
        });
    }
    const x0 = lerp(corners[0], corners[1], t[0]);
    const x1 = lerp(corners[2], corners[3], t[0]);
    const x2 = lerp(corners[4], corners[5], t[0]);
    const x3 = lerp(corners[6], corners[7], t[0]);
    return lerp(lerp(x0, x1, t[1]), lerp(x2, x3, t[1]), t[2]);
}

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6 - 15) + 10);
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

export fn up_seed_from_string(text: [*]const u8, length: usize) u64 {
    return seedFromString(text[0..length]);
}

export fn up_planet_create(params: *const Params) ?*Handle {
    const planet = Planet.create(std.heap.page_allocator, params.*) catch return null;
    return @ptrCast(planet);
}

export fn up_planet_destroy(handle: ?*Handle) void {
    const planet: *Planet = @ptrCast(@alignCast(handle orelse return));
    planet.destroy();
}

export fn up_planet_vertex_count(handle: *const Handle) u32 {
    return @intCast(planetOf(handle).elevations.len);
}

export fn up_planet_positions(handle: *const Handle) [*]const f32 {
    return planetOf(handle).positions.ptr;
}

export fn up_planet_elevations(handle: *const Handle) [*]const f32 {
    return planetOf(handle).elevations.ptr;
}

export fn up_planet_addresses(handle: *const Handle) [*]const u64 {
    return planetOf(handle).addresses.ptr;
}

export fn up_planet_index_count(handle: *const Handle) u32 {
    return @intCast(planetOf(handle).indices.len);
}

export fn up_planet_indices(handle: *const Handle) [*]const u32 {
    return planetOf(handle).indices.ptr;
}

export fn up_planet_radius(handle: *const Handle) f64 {
    return planetOf(handle).radius();
}

export fn up_planet_sea_level(handle: *const Handle) f32 {
    return planetOf(handle).sea_level;
}

export fn up_planet_min_elevation(handle: *const Handle) f32 {
    return planetOf(handle).min_elevation;
}

export fn up_planet_max_elevation(handle: *const Handle) f32 {
    return planetOf(handle).max_elevation;
}

export fn up_planet_sun_direction(handle: *const Handle, seconds: f64, out: *[3]f32) void {
    const s = planetOf(handle).sunDirection(seconds);
    for (0..3) |k| out[k] = @floatCast(s[k]);
}

// Tests

const earth: Params = .{
    .seed = 42,
    .radius_scale = 1,
    .region_scale = 1,
    .sea_level = 0.55,
    .axial_tilt = 23.44,
    .day_length = 1,
    .year_length = 1,
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
    const planet = try Planet.create(std.testing.allocator, earth);
    defer planet.destroy();
    const s = planet.sunDirection(earth_year / 4);
    try std.testing.expectApproxEqAbs(@sin(std.math.degreesToRadians(23.44)), s[1], 1e-9);
}

test "seeds from text" {
    try std.testing.expectEqual(@as(u64, 9000), seedFromString("9000"));
    try std.testing.expectEqual(seedFromString("perihelion"), seedFromString("perihelion"));
    try std.testing.expect(seedFromString("hal") != seedFromString("art"));
}
