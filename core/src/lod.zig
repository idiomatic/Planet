//! Level of detail: which patches to draw for a view, and the bookkeeping of the patches
//! cached between frames. The caller lends vertex storage per slot (`Storage`), and either
//! generates requested patches itself (in the background, installing them as they arrive) or
//! lets a synchronous selection generate everything it needs.

const std = @import("std");
const core = @import("root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = @Vector(3, f32);
const Plane = @Vector(4, f32);

/// A patch's name: level, base face, and path (one child index, 0...3, per level).
pub const Key = extern struct {
    level: u32,
    face: u32,
    path: u64,

    fn child(self: Key, index: u64) Key {
        return .{ .level = self.level + 1, .face = self.face, .path = self.path * 4 + index };
    }
};

/// A patch to draw: its slot (the caller's vertex buffer), and the vertex shader's constants.
pub const Draw = extern struct {
    slot: u32,
    skirt_depth: f32,
    parent_edge: f32,
};

pub const Stats = extern struct {
    /// Cached patches the last selection used (hits); requested ones were misses.
    visited: u32,
    cached: u32,
    pending: u32,
    /// Patches installed since the last selection began.
    generated: u32,
    cached_bytes: u64,
    /// Total time spent generating patches here (synchronously), in seconds.
    generation_seconds: f64,
};

/// Floats and bytes of one patch's vertices.
pub const patch_floats = core.patch_vertices * core.patch_vertex_floats;
pub const patch_bytes = patch_floats * @sizeOf(f32);

/// Vertex storage the caller lends per slot, called back only during this module's calls.
pub const Storage = extern struct {
    context: ?*anyopaque,
    /// Storage for `patch_floats` floats for the slot, lent until `release`; null if none.
    acquire: *const fn (context: ?*anyopaque, slot: u32) callconv(.c) ?[*]f32,
    /// The slot's patch was evicted; its storage is no longer used.
    release: *const fn (context: ?*anyopaque, slot: u32) callconv(.c) void,
};

pub const InstallError = Allocator.Error || error{NoStorage};

/// A cached patch: its vertices (borrowed) and its bounding sphere, in radii. The vertices
/// don't depend on exaggeration or sea level (the shader displaces them), but the bounds and
/// skirt do, so they're refit when either changes.
const Patch = struct {
    key: Key,
    vertices: [*]const f32,
    center: Vec3,
    radius: f32,
    /// How far the skirt hangs below the surface, in radii.
    skirt_depth: f32,
    last_used: u64,
    live: bool,
};

const Want = struct { pixels: f32, key: Key };

pub const Lod = struct {
    gpa: Allocator,
    params: core.Params,
    storage: Storage,
    /// Most patches kept; least recently used ones beyond this are evicted (40 MB's worth, by
    /// default, as the app's).
    capacity: u32 = 40_000_000 / patch_bytes,
    /// Triangle edge, in pixels, above which a patch is refined.
    target_pixels: f32 = 12,
    /// Radii per meter of elevation, with exaggeration.
    scale: f32,
    /// Sea level, in meters; oceans sit at it.
    sea_level: f32,

    slots: std.MultiArrayList(Patch) = .empty,
    free: std.ArrayList(u32) = .empty,
    index: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    pending: std.AutoHashMapUnmanaged(Key, void) = .empty,
    frame: u64 = 0,
    visited: u32 = 0,
    generated: u32 = 0,
    generation_ns: i96 = 0,

    // Each selection's results, reused from frame to frame.
    wanted: std.ArrayList(Want) = .empty,
    draws: std.ArrayList(Draw) = .empty,
    requests: std.ArrayList(Key) = .empty,
    stale: std.ArrayList(u32) = .empty,

    /// The 20 base patches are generated at the first selection. `storage` isn't called back
    /// from `deinit`: the caller's storage may be going away too.
    pub fn init(gpa: Allocator, params: core.Params, storage: Storage, scale: f32, sea_level: f32) Lod {
        return .{ .gpa = gpa, .params = params, .storage = storage, .scale = scale, .sea_level = sea_level };
    }

    pub fn deinit(self: *Lod) void {
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.wanted.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.requests.deinit(self.gpa);
        self.stale.deinit(self.gpa);
    }

    pub fn stats(self: *const Lod) Stats {
        return .{
            .visited = self.visited,
            .cached = self.index.count(),
            .pending = self.pending.count(),
            .generated = self.generated,
            .cached_bytes = @as(u64, self.index.count()) * patch_bytes,
            .generation_seconds = @as(f64, @floatFromInt(self.generation_ns)) / std.time.ns_per_s,
        };
    }

    /// Keeps at most `bytes` of patches (at least one).
    pub fn setCapacityBytes(self: *Lod, bytes: u64) void {
        self.capacity = @intCast(@min(@max(bytes / patch_bytes, 1), std.math.maxInt(u32)));
    }

    /// Changes the surface's scale or sea level, refitting every cached patch.
    pub fn setSurface(self: *Lod, scale: f32, sea_level: f32) void {
        if (scale == self.scale and sea_level == self.sea_level) return;
        self.scale = scale;
        self.sea_level = sea_level;
        for (self.slots.items(.live), 0..) |live, slot| {
            if (live) self.fit(@intCast(slot));
        }
    }

    /// Caches a patch generated elsewhere, copying its `patch_floats` vertices into storage.
    /// Returns its slot, or null if it's already cached.
    pub fn install(self: *Lod, key: Key, vertices: []const f32) InstallError!?u32 {
        _ = self.pending.remove(key);
        if (self.index.contains(key)) return null;
        return try self.place(key, vertices);
    }

    /// Generates a patch here, straight into storage, and caches it.
    fn generate(self: *Lod, key: Key) InstallError!void {
        _ = self.pending.remove(key);
        if (self.index.contains(key)) return;
        _ = try self.place(key, null);
    }

    /// Takes a slot and its storage, fills it (copying `vertices`, or generating them), and
    /// caches the patch there.
    fn place(self: *Lod, key: Key, vertices: ?[]const f32) InstallError!u32 {
        try self.index.ensureUnusedCapacity(self.gpa, 1);
        try self.free.ensureUnusedCapacity(self.gpa, 1);
        const slot: u32 = if (self.free.pop()) |slot| slot else slot: {
            try self.slots.append(self.gpa, undefined);
            self.slots.items(.live)[self.slots.len - 1] = false;
            break :slot @intCast(self.slots.len - 1);
        };
        const out = self.storage.acquire(self.storage.context, slot) orelse {
            self.free.appendAssumeCapacity(slot);
            return error.NoStorage;
        };
        if (vertices) |v| {
            @memcpy(out[0..patch_floats], v[0..patch_floats]);
        } else {
            const start = now();
            core.generatePatch(self.params, @intCast(key.level), @intCast(key.face), key.path, out[0..patch_floats]);
            self.generation_ns += now() - start;
        }
        self.slots.set(slot, .{
            .key = key,
            .vertices = out,
            .center = @splat(0),
            .radius = 0,
            .skirt_depth = 0,
            // New, not least recently used: a full cache would otherwise evict it first.
            .last_used = self.frame,
            .live = true,
        });
        self.fit(slot);
        self.index.putAssumeCapacity(key, slot);
        self.generated += 1;
        return slot;
    }

    /// Selects the patches to draw for a view (the coarsest that look fine) and evicts stale
    /// ones beyond the capacity. Then either requests up to `max_in_flight` pending patches (the
    /// most visible missing ones first) for the caller to generate, or, when `synchronous`,
    /// generates every missing one and selects again until none is. The results are in `draws`
    /// and `requests` until the next selection. `view_projection` is column-major, with reverse
    /// Z and no far plane.
    pub fn select(
        self: *Lod,
        view_projection: *const [16]f32,
        camera: Vec3,
        pixels_per_radian: f32,
        max_in_flight: u32,
        synchronous: bool,
    ) InstallError!void {
        return self.selectWith(frustumPlanes(view_projection), camera, pixels_per_radian, max_in_flight, synchronous);
    }

    /// Generates the 20 base patches, where selection starts, if they're missing.
    pub fn prepare(self: *Lod) InstallError!void {
        for (0..20) |face| try self.generate(.{ .level = 0, .face = @intCast(face), .path = 0 });
    }

    fn selectWith(
        self: *Lod,
        planes: [5]Plane,
        camera: Vec3,
        pixels_per_radian: f32,
        max_in_flight: u32,
        synchronous: bool,
    ) InstallError!void {
        self.generated = 0;
        try self.prepare();
        if (!synchronous) return self.selectPlanes(planes, camera, pixels_per_radian, max_in_flight);
        while (true) {
            try self.selectPlanes(planes, camera, pixels_per_radian, std.math.maxInt(u32));
            if (self.requests.items.len == 0) return;
            for (self.requests.items) |key| try self.generate(key);
        }
    }

    fn selectPlanes(
        self: *Lod,
        planes: [5]Plane,
        camera: Vec3,
        pixels_per_radian: f32,
        max_in_flight: u32,
    ) Allocator.Error!void {
        self.frame += 1;
        self.visited = 0;
        self.wanted.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
        self.requests.clearRetainingCapacity();
        const view: View = .{ .planes = planes, .camera = camera, .pixels_per_radian = pixels_per_radian };
        for (0..20) |face| try self.visit(.{ .level = 0, .face = @intCast(face), .path = 0 }, view);
        // Requests are rebuilt each frame, so a patch the camera has passed is never generated;
        // only those in flight may be.
        std.mem.sort(Want, self.wanted.items, {}, moreVisible);
        for (self.wanted.items) |want| {
            if (self.pending.count() >= max_in_flight) break;
            try self.pending.put(self.gpa, want.key, {});
            try self.requests.append(self.gpa, want.key);
        }
        try self.evict();
    }

    const View = struct { planes: [5]Plane, camera: Vec3, pixels_per_radian: f32 };

    fn moreVisible(_: void, a: Want, b: Want) bool {
        return a.pixels > b.pixels;
    }

    fn visit(self: *Lod, key: Key, view: View) Allocator.Error!void {
        const slot = self.index.get(key) orelse return;
        const s = self.slots.slice();
        s.items(.last_used)[slot] = self.frame;
        self.visited += 1;
        const center = s.items(.center)[slot];
        const radius = s.items(.radius)[slot];
        if (self.culled(center, radius, view)) return;
        if (key.level < core.max_patch_level) {
            if (self.refinementPixels(key.level, center, radius, view)) |pixels| {
                var missing: u32 = 0;
                for (0..4) |i| {
                    if (!self.index.contains(key.child(i))) missing += 1;
                }
                if (missing == 0) {
                    for (0..4) |i| try self.visit(key.child(i), view);
                    return;
                }
                for (0..4) |i| {
                    const child = key.child(i);
                    if (self.index.get(child)) |child_slot| {
                        // Keep the children that have arrived while their siblings are
                        // generated: evicting them as unused would leave the parent waiting
                        // forever once the cache is full.
                        s.items(.last_used)[child_slot] = self.frame;
                    } else if (!self.pending.contains(child)) {
                        try self.wanted.append(self.gpa, .{ .pixels = pixels, .key = child });
                    }
                }
            }
        }
        try self.draws.append(self.gpa, .{
            .slot = slot,
            .skirt_depth = s.items(.skirt_depth)[slot],
            .parent_edge = if (key.level > 0) 2 * triangleEdge(key.level) else 0,
        });
    }

    /// The patch's triangle size on screen, in pixels, if it's above `target_pixels`.
    fn refinementPixels(self: *const Lod, level: u32, center: Vec3, radius: f32, view: View) ?f32 {
        const distance = @max(length(view.camera - center) - radius, 1e-7);
        const pixels = triangleEdge(level) / distance * view.pixels_per_radian;
        return if (pixels > self.target_pixels) pixels else null;
    }

    fn culled(self: *const Lod, center: Vec3, radius: f32, view: View) bool {
        for (view.planes) |plane| {
            if (dot(.{ plane[0], plane[1], plane[2] }, center) + plane[3] < -radius) return true;
        }
        // Behind the horizon of the lowest surface (sea level, or the deepest land below it).
        const occluder = @min(1, 1 + self.scale * self.sea_level) * 0.999;
        const d = length(view.camera);
        const c = length(center);
        if (!(d > occluder and c > 0)) return false;
        const angle = std.math.acos(std.math.clamp(dot(view.camera / splat(d), center / splat(c)), -1, 1));
        const extent = std.math.asin(@min(radius / c, 1));
        const horizon = std.math.acos(occluder / d) + std.math.acos(@min(occluder / (c + radius), 1));
        return angle - extent > horizon;
    }

    /// Fits the slot's bounds and skirt to the scale and sea level.
    fn fit(self: *Lod, slot: u32) void {
        const s = self.slots.slice();
        const vertices = s.items(.vertices)[slot];
        var lo: Vec3 = @splat(std.math.inf(f32));
        var hi: Vec3 = @splat(-std.math.inf(f32));
        for (0..core.patch_vertices) |v| {
            const p = self.point(vertices, v);
            lo = @min(lo, p);
            hi = @max(hi, p);
        }
        const center = (lo + hi) / splat(2);
        var radius: f32 = 0;
        for (0..core.patch_vertices) |v| radius = @max(radius, length(self.point(vertices, v) - center));
        s.items(.center)[slot] = center;
        s.items(.radius)[slot] = radius;
        s.items(.skirt_depth)[slot] = triangleEdge(s.items(.key)[slot].level) + self.scale * 500;
    }

    fn point(self: *const Lod, vertices: [*]const f32, v: usize) Vec3 {
        const f = v * core.patch_vertex_floats;
        const direction: Vec3 = .{ vertices[f], vertices[f + 1], vertices[f + 2] };
        return direction * splat(1 + self.scale * @max(vertices[f + 3], self.sea_level));
    }

    /// Evicts the least recently used patches beyond the capacity, never the roots or those
    /// this selection used.
    fn evict(self: *Lod) Allocator.Error!void {
        const count = self.index.count();
        if (count <= self.capacity) return;
        self.stale.clearRetainingCapacity();
        const s = self.slots.slice();
        for (s.items(.live), s.items(.key), s.items(.last_used), 0..) |live, key, last_used, slot| {
            if (live and key.level > 0 and last_used < self.frame) try self.stale.append(self.gpa, @intCast(slot));
        }
        std.mem.sort(u32, self.stale.items, s.items(.last_used), lessRecentlyUsed);
        const excess = @min(count - self.capacity, self.stale.items.len);
        for (self.stale.items[0..excess]) |slot| {
            _ = self.index.remove(s.items(.key)[slot]);
            s.items(.live)[slot] = false;
            try self.free.append(self.gpa, slot);
            self.storage.release(self.storage.context, slot);
        }
    }

    fn lessRecentlyUsed(last_used: []const u64, a: u32, b: u32) bool {
        return last_used[a] < last_used[b];
    }
};

fn now() i96 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
}

/// Edge of a patch's lattice triangles, in radii (the icosahedron's edge is ~1.05).
pub fn triangleEdge(level: u32) f32 {
    return 1.05 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(level + core.patch_subdivisions)));
}

/// Left, right, bottom, top, and near planes of a column-major matrix's frustum, pointing
/// inward and normalized (reverse Z with an infinite far plane has no far plane).
fn frustumPlanes(m: *const [16]f32) [5]Plane {
    const row = struct {
        fn of(matrix: *const [16]f32, r: usize) Plane {
            return .{ matrix[r], matrix[4 + r], matrix[8 + r], matrix[12 + r] };
        }
    }.of;
    const r0 = row(m, 0);
    const r1 = row(m, 1);
    const r2 = row(m, 2);
    const r3 = row(m, 3);
    var planes = [5]Plane{ r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 - r2 };
    for (&planes) |*plane| plane.* /= @splat(length(.{ plane[0], plane[1], plane[2] }));
    return planes;
}

fn splat(x: f32) Vec3 {
    return @splat(x);
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn length(v: Vec3) f32 {
    return @sqrt(dot(v, v));
}

// Tests

const testing = std.testing;

/// A cache for Earth's parameters, lending it storage per slot and noting released slots.
const Fixture = struct {
    lod: Lod,
    storage: std.ArrayList([]f32) = .empty,
    released: std.ArrayList(u32) = .empty,

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        const storage: Storage = .{ .context = self, .acquire = acquire, .release = release };
        self.* = .{ .lod = .init(testing.allocator, core.earth, storage, 100.0 / 6_371_000.0, 0) };
        try self.lod.prepare();
        return self;
    }

    fn destroy(self: *Fixture) void {
        for (self.storage.items) |v| testing.allocator.free(v);
        self.storage.deinit(testing.allocator);
        self.released.deinit(testing.allocator);
        self.lod.deinit();
        testing.allocator.destroy(self);
    }

    fn acquire(context: ?*anyopaque, slot: u32) callconv(.c) ?[*]f32 {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        while (self.storage.items.len <= slot) {
            const v = testing.allocator.alloc(f32, patch_floats) catch return null;
            self.storage.append(testing.allocator, v) catch {
                testing.allocator.free(v);
                return null;
            };
        }
        return self.storage.items[slot].ptr;
    }

    fn release(context: ?*anyopaque, slot: u32) callconv(.c) void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.released.append(testing.allocator, slot) catch {};
    }

    /// Installs a patch as background generation would: generated elsewhere, then copied in.
    fn install(self: *Fixture, key: Key) !?u32 {
        var vertices: [patch_floats]f32 = undefined;
        core.generatePatch(core.earth, @intCast(key.level), @intCast(key.face), key.path, &vertices);
        return self.lod.install(key, &vertices);
    }

    /// Selects with nothing outside the frustum, from `camera`.
    fn select(self: *Fixture, camera: Vec3, max_in_flight: u32) !void {
        try self.selectMode(camera, max_in_flight, false);
    }

    fn selectMode(self: *Fixture, camera: Vec3, max_in_flight: u32, synchronous: bool) !void {
        self.released.clearRetainingCapacity();
        const everywhere: Plane = .{ 0, 0, 0, 1 };
        try self.lod.selectWith(@splat(everywhere), camera, 2000, max_in_flight, synchronous);
    }
};

test "selection draws the roots from afar and refines near the camera, requesting the largest first" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.select(.{ 0, 0, 1000 }, 4);
    try testing.expectEqual(0, f.lod.requests.items.len);
    try testing.expect(f.lod.draws.items.len > 0 and f.lod.draws.items.len <= 20);

    try f.select(.{ 0, 0, 1.2 }, 4);
    try testing.expectEqual(4, f.lod.requests.items.len);
    try testing.expectEqual(4, f.lod.stats().pending);
    // Pending patches aren't requested again, and no more start while 4 are in flight.
    try f.select(.{ 0, 0, 1.2 }, 4);
    try testing.expectEqual(0, f.lod.requests.items.len);
    try f.select(.{ 0, 0, 1.2 }, 6);
    try testing.expectEqual(2, f.lod.requests.items.len);
}

test "a full cache keeps arrived children until their siblings arrive" {
    const f = try Fixture.create();
    defer f.destroy();
    f.lod.capacity = 20; // the roots alone fill it
    try f.select(.{ 0, 0, 1.2 }, 4);
    const children = f.lod.requests.items[0..4].*;
    // The 4 requested are one parent's children: the most visible missing patches.
    for (children[1..]) |child| try testing.expectEqual(children[0].path / 4, child.path / 4);
    _ = try f.install(children[0]);
    _ = try f.install(children[1]);
    try f.select(.{ 0, 0, 1.2 }, 4);
    try testing.expectEqual(0, f.released.items.len);
    try testing.expectEqual(22, f.lod.stats().cached);
    _ = try f.install(children[2]);
    _ = try f.install(children[3]);
    try f.select(.{ 0, 0, 1.2 }, 4);
    for (children) |child| {
        const slot = f.lod.index.get(child).?;
        var drawn = false;
        for (f.lod.draws.items) |d| drawn = drawn or d.slot == slot;
        try testing.expect(drawn);
    }
}

test "eviction removes the least recently used, never the roots, and reuses their slots" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.select(.{ 0, 0, 1.2 }, 4);
    const children = f.lod.requests.items[0..4].*;
    for (children) |child| _ = try f.install(child);
    try f.select(.{ 0, 0, 1.2 }, 0);
    try testing.expectEqual(24, f.lod.stats().cached);

    // From afar, the children go unused; a capacity of 21 evicts 3 of them, oldest first.
    f.lod.capacity = 21;
    try f.select(.{ 0, 0, 1000 }, 0);
    try testing.expectEqual(3, f.released.items.len);
    try testing.expectEqual(21, f.lod.stats().cached);
    for (0..20) |face| try testing.expect(f.lod.index.contains(.{ .level = 0, .face = @intCast(face), .path = 0 }));
    try testing.expect(std.mem.indexOfScalar(u32, f.released.items, (try f.install(children[0])).?) != null);
}

test "installing a cached patch is ignored, and installing a requested one clears it" {
    const f = try Fixture.create();
    defer f.destroy();
    try testing.expectEqual(null, try f.install(.{ .level = 0, .face = 3, .path = 0 }));
    try f.select(.{ 0, 0, 1.2 }, 1);
    try testing.expect((try f.install(f.lod.requests.items[0])) != null);
    try testing.expectEqual(0, f.lod.stats().pending);
}

test "a synchronous selection generates everything it needs, once" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.selectMode(.{ 0, 0, 1.2 }, 4, true);
    try testing.expectEqual(0, f.lod.requests.items.len);
    try testing.expectEqual(0, f.lod.stats().pending);
    try testing.expect(f.lod.stats().generated > 0);
    try testing.expect(f.lod.stats().generation_seconds > 0);
    const drawn = f.lod.draws.items.len;
    try f.selectMode(.{ 0, 0, 1.2 }, 4, true);
    try testing.expectEqual(0, f.lod.stats().generated);
    try testing.expectEqual(drawn, f.lod.draws.items.len);
    // The same view, selected in the background, finds nothing missing.
    try f.select(.{ 0, 0, 1.2 }, 4);
    try testing.expectEqual(0, f.lod.requests.items.len);
}

test "the capacity in bytes holds whole patches, at least one" {
    const f = try Fixture.create();
    defer f.destroy();
    f.lod.setCapacityBytes(40_000_000);
    try testing.expectEqual(40_000_000 / patch_bytes, f.lod.capacity);
    f.lod.setCapacityBytes(1);
    try testing.expectEqual(1, f.lod.capacity);
}

test "frustum planes of the identity are the clip cube's sides, pointing inward" {
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const planes = frustumPlanes(&identity);
    try testing.expectEqual(Plane{ 1, 0, 0, 1 }, planes[0]);
    try testing.expectEqual(Plane{ -1, 0, 0, 1 }, planes[1]);
    try testing.expectEqual(Plane{ 0, 0, -1, 1 }, planes[4]);
}
