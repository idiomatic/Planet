import Metal
import QuartzCore
import simd

/// A patch's name: level, base face, and path (one child index, 0...3, per level).
struct PatchKey: Hashable, Sendable {
    var level: UInt32
    var face: UInt32
    var path: UInt64

    var children: [PatchKey] {
        (0..<4).map { PatchKey(level: level + 1, face: face, path: path * 4 + UInt64($0)) }
    }
}

/// A generated patch on the GPU, with a bounding sphere in radii.
final class Patch {
    let buffer: MTLBuffer
    let center: SIMD3<Float>
    let radius: Float
    /// How far the skirt hangs below the surface, in radii.
    let skirtDepth: Float
    /// Edge of the parent's lattice triangles, in radii (0 for a base face, which has no parent).
    let parentEdge: Float
    var lastUsed = 0

    init(buffer: MTLBuffer, center: SIMD3<Float>, radius: Float, skirtDepth: Float, parentEdge: Float) {
        self.buffer = buffer
        self.center = center
        self.radius = radius
        self.skirtDepth = skirtDepth
        self.parentEdge = parentEdge
    }
}

/// What the camera sees, for choosing patches.
struct PatchView {
    var camera: SIMD3<Float>
    /// Planes of the view frustum (left, right, bottom, top, near), pointing inward.
    var planes: [SIMD4<Float>]
    var pixelsPerRadian: Float
}

/// Chooses patches for the view each frame, refining where their triangles would look large,
/// and caches them between frames. Missing patches are generated in the background while their
/// parent is drawn, or immediately when `synchronous`.
@MainActor
final class PatchCache {
    let indexBuffer: MTLBuffer
    let surfaceIndexCount: Int
    let indexCount: Int
    var synchronous = false

    /// Most patches kept; least recently used ones beyond this are evicted.
    var capacity = 4096
    /// Triangle edge, in pixels, above which a patch is refined.
    var targetPixels: Float = 12

    private(set) var drawn = 0
    /// Cached patches the last selection used (hits); generated ones were misses.
    private(set) var visited = 0
    private(set) var generatedThisFrame = 0
    private(set) var generationSeconds = 0.0
    var cachedCount: Int { patches.count }

    private let planet: Planet
    private let device: MTLDevice
    private let maxLevel: UInt32
    private let vertexCount: Int
    /// Radii per meter of elevation, with exaggeration.
    private let scale: Float
    private let seaLevel: Float
    private var patches: [PatchKey: Patch] = [:]
    private var pending: Set<PatchKey> = []
    /// Patches this selection wanted but lacked, with their parent's triangle size on screen.
    private var wanted: [(pixels: Float, key: PatchKey)] = []
    /// Leaves two cores for the main thread and the window server.
    private let maxInFlight = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)
    private var frame = 0

    /// Called when a background patch arrives, so the view can draw it.
    var onInstall: (() -> Void)?

    nonisolated private static let floatsPerVertex = 12
    private static let roots = (0..<20).map { PatchKey(level: 0, face: UInt32($0), path: 0) }

    init?(planet: Planet, device: MTLDevice, scale: Float) {
        let indexCount = Int(up_patch_index_count())
        var indices = [UInt32](repeating: 0, count: indexCount)
        up_patch_indices(&indices)
        guard let indexBuffer = device.makeBuffer(
            bytes: indices, length: indexCount * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        else { return nil }
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
        self.surfaceIndexCount = Int(up_patch_surface_index_count())
        self.vertexCount = Int(up_patch_vertex_count())
        self.maxLevel = up_patch_max_level()
        self.planet = planet
        self.device = device
        self.scale = scale
        self.seaLevel = planet.seaLevel
        for key in Self.roots { install(key, Self.vertices(planet, key)) }
    }

    /// Patches to draw for `view`, coarsest that look fine; evicts stale ones.
    func select(_ view: PatchView) -> [Patch] {
        frame += 1
        generatedThisFrame = 0
        visited = 0
        wanted.removeAll(keepingCapacity: true)
        var list: [Patch] = []
        for key in Self.roots { visit(key, view, &list) }
        drawn = list.count
        // Generate the most visible missing patches first. Requests are rebuilt each frame,
        // so a patch the camera has passed is never generated; only those in flight may be.
        for (_, key) in wanted.sorted(by: { $0.pixels > $1.pixels }) where pending.count < maxInFlight {
            request(key)
        }
        evict()
        return list
    }

    private func visit(_ key: PatchKey, _ view: PatchView, _ list: inout [Patch]) {
        guard let patch = patches[key] else { return }
        patch.lastUsed = frame
        visited += 1
        if culled(patch, view) { return }
        if key.level < maxLevel, let pixels = refinementPixels(key, patch, view) {
            let children = key.children
            var missing = children.filter { patches[$0] == nil }
            if synchronous {
                for child in missing {
                    let start = CACurrentMediaTime()
                    let vertices = Self.vertices(planet, child)
                    generationSeconds += CACurrentMediaTime() - start
                    install(child, vertices)
                }
                missing = []
            } else {
                for child in missing where !pending.contains(child) { wanted.append((pixels, child)) }
            }
            if missing.isEmpty {
                for child in children { visit(child, view, &list) }
                return
            }
        }
        list.append(patch)
    }

    /// The patch's triangle size on screen, in pixels, if it's above `targetPixels`.
    private func refinementPixels(_ key: PatchKey, _ patch: Patch, _ view: PatchView) -> Float? {
        let distance = max(length(view.camera - patch.center) - patch.radius, 1e-7)
        let pixels = Self.triangleEdge(key.level) / distance * view.pixelsPerRadian
        return pixels > targetPixels ? pixels : nil
    }

    private func culled(_ patch: Patch, _ view: PatchView) -> Bool {
        for plane in view.planes where dot(SIMD3(plane.x, plane.y, plane.z), patch.center) + plane.w < -patch.radius {
            return true
        }
        // Behind the horizon of the lowest surface (sea level, or the deepest land below it).
        let occluder = min(1, 1 + scale * seaLevel) * 0.999
        let d = length(view.camera)
        let c = length(patch.center)
        guard d > occluder, c > 0 else { return false }
        let angle = acos(min(max(dot(view.camera / d, patch.center / c), -1), 1))
        let extent = asin(min(patch.radius / c, 1))
        let horizon = acos(occluder / d) + acos(min(occluder / (c + patch.radius), 1))
        return angle - extent > horizon
    }

    private func request(_ key: PatchKey) {
        guard !pending.contains(key), pending.count < maxInFlight else { return }
        pending.insert(key)
        let planet = planet
        Task.detached(priority: .utility) {
            let vertices = Self.vertices(planet, key)
            await self.install(key, vertices)
        }
    }

    private func install(_ key: PatchKey, _ vertices: [Float]) {
        pending.remove(key)
        guard patches[key] == nil,
              let buffer = device.makeBuffer(
                  bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { return }
        generatedThisFrame += 1

        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(vertexCount)
        for v in 0..<vertexCount {
            let f = v * Self.floatsPerVertex
            let direction = SIMD3(vertices[f], vertices[f + 1], vertices[f + 2])
            let point = direction * (1 + scale * max(vertices[f + 3], seaLevel))
            points.append(point)
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        let center = (lo + hi) / 2
        let radius = points.map { length($0 - center) }.max() ?? 0
        let skirtDepth = Self.triangleEdge(key.level) + scale * 500
        let parentEdge = key.level > 0 ? 2 * Self.triangleEdge(key.level) : 0
        patches[key] = Patch(
            buffer: buffer, center: center, radius: radius, skirtDepth: skirtDepth, parentEdge: parentEdge)
        onInstall?()
    }

    private func evict() {
        guard patches.count > capacity else { return }
        let stale = patches
            .filter { $0.key.level > 0 && $0.value.lastUsed < frame }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, _) in stale.prefix(patches.count - capacity) { patches[key] = nil }
    }

    /// Edge of a patch's lattice triangles, in radii (the icosahedron's edge is ~1.05).
    private static func triangleEdge(_ level: UInt32) -> Float {
        1.05 / Float(1 << (Int(level) + 4))
    }

    nonisolated private static func vertices(_ planet: Planet, _ key: PatchKey) -> [Float] {
        var vertices = [Float](repeating: 0, count: Int(up_patch_vertex_count()) * floatsPerVertex)
        planet.generatePatch(key, into: &vertices)
        return vertices
    }
}
