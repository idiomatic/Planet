import MetalKit
import simd

/// Draws a planet and flies a camera around it. Distances are in planet radii.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let planet: Planet
    var boost = false

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let floorRadius: Float

    private var position = SIMD3<Float>(0, 0, 3)
    private var orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var keys: Set<String> = []
    private var aspect: Float = 1
    private var lastFrame: CFTimeInterval?
    private var simulatedSeconds = 0.0
    /// Whether to draw the mesh's edges over the surface.
    var showMesh = false

    /// Percent; 100 is real time and 0 is paused.
    var timeSpeed = 360_000.0 {
        didSet { timeSpeed = min(max(timeSpeed, 0), 1e9) }
    }

    /// Altitude, in radii, below which flight and zoom stop slowing (~3 km at Earth's radius),
    /// so the camera can leave the floor quickly.
    private static let minimumAltitude: Float = 5e-4

    private struct Uniforms {
        var viewProjection: simd_float4x4
        var sun: SIMD4<Float>
        var elevation: SIMD4<Float>
    }

    init?(planet: Planet) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }

        let (vertices, top) = Renderer.vertices(for: planet)
        let indices = planet.indices
        guard let vertexBuffer = vertices.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              }),
              let indexBuffer = device.makeBuffer(
                  bytes: indices.baseAddress!,
                  length: indices.count * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              )
        else { return nil }

        self.device = device
        self.planet = planet
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
        self.floorRadius = top + 1e-5
    }

    /// Interleaved position, normal, and elevation per vertex, displaced radially with
    /// oceans flattened to sea level; also returns the highest radius.
    private static func vertices(for planet: Planet) -> ([Float], Float) {
        let count = planet.vertexCount
        let positions = planet.positions
        let elevations = planet.elevations
        let sea = planet.seaLevel
        let scale = Float(planet.parameters.radialExaggeration / 100 / planet.radius)

        var points = [SIMD3<Float>](repeating: .zero, count: count)
        var top: Float = 1
        for i in 0..<count {
            let direction = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            let r = 1 + max(elevations[i], sea) * scale
            points[i] = direction * r
            top = max(top, r)
        }

        var normals = [SIMD3<Float>](repeating: .zero, count: count)
        let indices = planet.indices
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            var n = cross(points[b] - points[a], points[c] - points[a])
            if dot(n, points[a]) < 0 { n = -n }
            normals[a] += n
            normals[b] += n
            normals[c] += n
        }

        var vertices = [Float]()
        vertices.reserveCapacity(count * 7)
        for i in 0..<count {
            let n = elevations[i] < sea ? normalize(points[i]) : normalize(normals[i])
            vertices += [points[i].x, points[i].y, points[i].z, n.x, n.y, n.z, elevations[i]]
        }
        return (vertices, top)
    }

    // MARK: Input

    /// Returns whether the key was handled.
    func keyDown(_ key: String, repeated: Bool) -> Bool {
        switch key {
        case "w", "a", "s", "d", "r", "f", "q", "e":
            keys.insert(key)
        case "m":
            if !repeated { showMesh.toggle() }
        case ",":
            if !repeated { timeSpeed = timeSpeed > 1 ? max(timeSpeed / 10, 1) : 0 }
        case ".":
            if !repeated { timeSpeed = max(timeSpeed * 10, 1) }
        default:
            return false
        }
        return true
    }

    func keyUp(_ key: String) {
        keys.remove(key)
    }

    func look(dx: Float, dy: Float) {
        let yaw = simd_quatf(angle: -dx * 0.003, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: -dy * 0.003, axis: SIMD3(1, 0, 0))
        orientation = (orientation * yaw * pitch).normalized
    }

    /// Moves along the view direction by a fraction of the altitude: positive `amount` moves in.
    func zoom(_ amount: Float) {
        let altitude = max(length(position) - floorRadius, Renderer.minimumAltitude)
        let step = altitude * (1 - exp(-amount))
        position += orientation.act(SIMD3(0, 0, -1)) * step
        if length(position) < floorRadius { position = normalize(position) * floorRadius }
    }

    // MARK: Status

    var status: String {
        let altitude = (length(position) - 1) * Float(planet.radius / 1000)
        let days = simulatedSeconds / (86_400 * planet.parameters.dayLength)
        return String(
            format: "seed %@ · time %@%% · day %.2f · altitude %.0f km\n"
                + "drag: look · wheel: zoom · W/S: forward/back · A/D: left/right · R/F: up/down · "
                + "Q/E: roll · shift: faster · M: mesh · ,/.: time slower/faster",
            planet.parameters.seed,
            timeSpeed.formatted(.number.precision(.fractionLength(0))),
            days,
            altitude
        )
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 { aspect = Float(size.width / size.height) }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - (lastFrame ?? now), 0.1))
        lastFrame = now
        simulatedSeconds += Double(dt) * timeSpeed / 100
        fly(dt)

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer()
        else { return }
        encode(commands, pass)
        commands.present(drawable)
        commands.commit()
    }

    /// Puts the camera at `position` looking at `target`, with the planet's radial direction up
    /// (or +y when looking straight down), and sets the simulated time.
    func place(_ camera: Camera) {
        position = camera.position
        if length(position) < floorRadius { position = normalize(position) * floorRadius }
        let forward = normalize(camera.target - camera.position)
        let up = normalize(camera.position)
        let reference = abs(dot(forward, up)) > 0.99 ? SIMD3<Float>(0, 1, 0) : up
        let right = normalize(cross(forward, abs(dot(forward, reference)) > 0.99 ? SIMD3(1, 0, 0) : reference))
        orientation = simd_quatf(simd_float3x3(right, cross(right, forward), -forward))
        simulatedSeconds = camera.seconds
    }

    /// Renders one frame offscreen from the current camera.
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard let pass = offscreenPass(width: width, height: height),
              renderOffscreen(pass) != nil,
              let color = pass.colorAttachments[0].texture
        else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        color.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Renders one frame into `pass` and waits for it; returns the completed command buffer.
    func renderOffscreen(_ pass: MTLRenderPassDescriptor) -> MTLCommandBuffer? {
        guard let commands = queue.makeCommandBuffer() else { return nil }
        encode(commands, pass)
        commands.commit()
        commands.waitUntilCompleted()
        return commands
    }

    /// A render pass with offscreen color and depth targets, and the aspect set to match.
    func offscreenPass(width: Int, height: Int) -> MTLRenderPassDescriptor? {
        aspect = Float(width) / Float(height)

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor)
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        return pass
    }

    private func encode(_ commands: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor) {
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let altitude = length(position) - floorRadius
        let projection = simd_float4x4(perspectiveFovY: .pi / 3, aspect: aspect, near: max(altitude * 0.5, 1e-6))
        let view = simd_float4x4(orientation.inverse) * simd_float4x4(translation: -position)
        var uniforms = Uniforms(
            viewProjection: projection * view,
            sun: SIMD4(planet.sunDirection(at: simulatedSeconds), 0),
            elevation: SIMD4(planet.minElevation, planet.seaLevel, planet.maxElevation, 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        drawTriangles(encoder)

        if showMesh {
            // Edges again as lines, pulled toward the camera (reverse-Z: greater is nearer).
            uniforms.elevation.w = 1
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setTriangleFillMode(.lines)
            encoder.setDepthBias(0, slopeScale: 1, clamp: 0)
            drawTriangles(encoder)
        }
        encoder.endEncoding()
    }

    private func drawTriangles(_ encoder: MTLRenderCommandEncoder) {
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    /// Moves at a speed proportional to altitude, so approaching the surface slows down.
    private func fly(_ dt: Float) {
        func axis(_ plus: String, _ minus: String) -> Float {
            (keys.contains(plus) ? 1 : 0) - (keys.contains(minus) ? 1 : 0)
        }
        let roll = axis("q", "e")
        if roll != 0 {
            orientation = (orientation * simd_quatf(angle: roll * dt, axis: SIMD3(0, 0, 1))).normalized
        }
        let local = SIMD3(axis("d", "a"), axis("r", "f"), axis("s", "w"))
        guard local != .zero else { return }
        let speed = max(length(position) - floorRadius, Renderer.minimumAltitude) * (boost ? 4 : 1)
        position += orientation.act(normalize(local)) * speed * dt
        if length(position) < floorRadius { position = normalize(position) * floorRadius }
    }
}
