import Metal
import QuartzCore
import simd

/// A patch's name: level, base face, and path (one child index, 0...3, per level).
typealias PatchKey = pl_patch_key

/// What the camera sees, for choosing patches.
struct PatchView {
    var viewProjection: simd_float4x4
    var camera: SIMD3<Float>
    var pixelsPerRadian: Float
}

/// A patch to draw: its vertices and the vertex shader's constants (skirt depth and the
/// parent's triangle edge, in radii).
struct PatchDraw {
    var buffer: MTLBuffer
    var constants: SIMD2<Float>
}

/// Keeps the patches' vertex buffers, generating them as the core's level of detail
/// (`pl_lod_*`) requests: in the background while their parent is drawn, or immediately when
/// `synchronous`. The core chooses what to draw and what to evict; this owns the buffers.
@MainActor
final class PatchCache {
    let indexBuffer: MTLBuffer
    let surfaceIndexCount: Int
    let indexCount: Int
    var synchronous = false

    /// Most bytes of patches kept; least recently used ones beyond this are evicted (on the next
    /// selection, so shrinking applies as soon as the view redraws).
    var capacityBytes = 40_000_000 {
        didSet { pl_lod_set_capacity(lod, UInt32(max(capacityBytes / patchBytes, 1))) }
    }
    /// Bytes per patch: its vertices (its share of the index buffer is shared by all).
    var patchBytes: Int { vertexCount * Self.floatsPerVertex * MemoryLayout<Float>.stride }
    /// Triangle edge, in pixels, above which a patch is refined.
    var targetPixels: Float = 12 {
        didSet { pl_lod_set_detail(lod, targetPixels) }
    }
    /// Radii per meter of elevation, with exaggeration; changing it refits every cached patch.
    var scale: Float {
        didSet { if scale != oldValue { pl_lod_set_surface(lod, scale, seaLevel) } }
    }
    /// Sea level in meters; oceans sit at it, so changing it also refits every cached patch.
    var seaLevel: Float {
        didSet { if seaLevel != oldValue { pl_lod_set_surface(lod, scale, seaLevel) } }
    }

    private(set) var drawn = 0
    /// Cached patches the last selection used (hits); generated ones were misses.
    private(set) var visited = 0
    private(set) var generatedThisFrame = 0
    private(set) var generationSeconds = 0.0
    var cachedCount: Int { Int(pl_lod_stats_get(lod).cached) }
    var cachedBytes: Int { cachedCount * patchBytes }

    private let planet: Planet
    private let device: MTLDevice
    private let vertexCount: Int
    /// The core's level of detail; destroyed in `deinit`, when nothing else can reach it.
    nonisolated(unsafe) private let lod: OpaquePointer
    /// Vertex buffers by the core's slot; the core borrows their contents until it evicts them.
    private var buffers: [MTLBuffer?] = []
    /// Leaves two cores for the main thread and the window server.
    private let maxInFlight = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)

    /// Called when a background patch arrives, so the view can draw it.
    var onInstall: (() -> Void)?

    nonisolated private static let floatsPerVertex = 12

    init?(planet: Planet, device: MTLDevice, scale: Float, seaLevel: Float) {
        let indexCount = Int(pl_patch_index_count())
        var indices = [UInt32](repeating: 0, count: indexCount)
        pl_patch_indices(&indices)
        guard let indexBuffer = device.makeBuffer(
            bytes: indices, length: indexCount * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let lod = pl_lod_create(scale, seaLevel)
        else { return nil }
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
        self.surfaceIndexCount = Int(pl_patch_surface_index_count())
        self.vertexCount = Int(pl_patch_vertex_count())
        self.planet = planet
        self.device = device
        self.scale = scale
        self.seaLevel = seaLevel
        self.lod = lod
        pl_lod_set_capacity(lod, UInt32(max(capacityBytes / patchBytes, 1)))
        for face in 0..<UInt32(20) {
            let key = PatchKey(level: 0, face: face, path: 0)
            install(key, Self.vertices(planet, key))
        }
    }

    deinit {
        pl_lod_destroy(lod)
    }

    /// Patches to draw for `view`, coarsest that look fine; requests missing ones and releases
    /// evicted ones. When synchronous, generates what's missing until none is.
    func select(_ view: PatchView) -> [PatchDraw] {
        generatedThisFrame = 0
        var camera = [view.camera.x, view.camera.y, view.camera.z]
        var matrix = view.viewProjection
        while true {
            let selected = withUnsafeBytes(of: &matrix) {
                pl_lod_select(
                    lod, $0.baseAddress!.assumingMemoryBound(to: Float.self), &camera, view.pixelsPerRadian,
                    synchronous ? .max : UInt32(maxInFlight))
            }
            guard selected else { return [] }
            for slot in Self.items(pl_lod_evicted, lod) { buffers[Int(slot)] = nil }
            let requests = Self.items(pl_lod_requests, lod)
            if !synchronous {
                requests.forEach(request)
                break
            }
            if requests.isEmpty { break }
            for key in requests {
                let start = CACurrentMediaTime()
                let vertices = Self.vertices(planet, key)
                generationSeconds += CACurrentMediaTime() - start
                install(key, vertices)
            }
        }
        visited = Int(pl_lod_stats_get(lod).visited)
        let draws = Self.items(pl_lod_draws, lod).compactMap { draw in
            buffers[Int(draw.slot)].map { PatchDraw(buffer: $0, constants: SIMD2(draw.skirt_depth, draw.parent_edge)) }
        }
        drawn = draws.count
        return draws
    }

    private func request(_ key: PatchKey) {
        let planet = planet
        Task.detached(priority: .utility) {
            let vertices = Self.vertices(planet, key)
            await self.install(key, vertices)
        }
    }

    private func install(_ key: PatchKey, _ vertices: [Float]) {
        guard let buffer = device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        else {
            pl_lod_cancel(lod, key)
            return
        }
        let slot = pl_lod_install(lod, key, buffer.contents().assumingMemoryBound(to: Float.self))
        guard slot >= 0 else { return } // already cached, or out of memory
        if slot >= buffers.count { buffers.append(contentsOf: repeatElement(nil, count: Int(slot) + 1 - buffers.count)) }
        buffers[Int(slot)] = buffer
        generatedThisFrame += 1
        onInstall?()
    }

    /// One of the core's per-selection lists, copied out.
    private static func items<T>(
        _ list: (OpaquePointer?, UnsafeMutablePointer<UInt32>?) -> UnsafePointer<T>?, _ lod: OpaquePointer
    ) -> [T] {
        var count: UInt32 = 0
        guard let items = list(lod, &count) else { return [] }
        return Array(UnsafeBufferPointer(start: items, count: Int(count)))
    }

    nonisolated private static func vertices(_ planet: Planet, _ key: PatchKey) -> [Float] {
        var vertices = [Float](repeating: 0, count: Int(pl_patch_vertex_count()) * floatsPerVertex)
        planet.generatePatch(key, into: &vertices)
        return vertices
    }
}
