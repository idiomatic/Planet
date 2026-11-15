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
    let patches: PatchCache
    /// Radii per meter of elevation, with exaggeration.
    private let scale: Float
    private let floorRadius: Float
    private var viewportHeight: Float = 800

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
        var display: SIMD4<Float>
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

        let scale = Float(planet.parameters.radialExaggeration / 100 / planet.radius)
        guard let patches = PatchCache(planet: planet, device: device, scale: scale) else { return nil }

        self.device = device
        self.planet = planet
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.patches = patches
        self.scale = scale
        // Above the highest point, with a margin for detail finer than the coarse mesh.
        self.floorRadius = 1 + scale * (max(planet.maxElevation, planet.seaLevel) + 500) + 1e-5
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
            format: "seed %@ · time %@%% · day %.2f · altitude %.0f km · patches %d drawn, %d cached\n"
                + "drag: look · wheel: zoom · W/S: forward/back · A/D: left/right · R/F: up/down · "
                + "Q/E: roll · shift: faster · M: mesh · ,/.: time slower/faster",
            planet.parameters.seed,
            timeSpeed.formatted(.number.precision(.fractionLength(0))),
            days,
            altitude,
            patches.drawn,
            patches.cachedCount
        )
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 {
            aspect = Float(size.width / size.height)
            viewportHeight = Float(size.height)
        }
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
        viewportHeight = Float(height)

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
        let fovY: Float = .pi / 3
        let projection = simd_float4x4(perspectiveFovY: fovY, aspect: aspect, near: max(altitude * 0.5, 1e-6))
        let view = simd_float4x4(orientation.inverse) * simd_float4x4(translation: -position)
        let viewProjection = projection * view
        var uniforms = Uniforms(
            viewProjection: viewProjection,
            sun: SIMD4(planet.sunDirection(at: simulatedSeconds), 0),
            elevation: SIMD4(planet.minElevation, planet.seaLevel, planet.maxElevation, 0),
            display: SIMD4(scale, 0, 0, 0)
        )
        let visible = patches.select(PatchView(
            camera: position,
            planes: Renderer.frustumPlanes(viewProjection),
            pixelsPerRadian: viewportHeight / (2 * tan(fovY / 2))
        ))

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        draw(visible, encoder, indexCount: patches.indexCount)

        if showMesh {
            // Surface edges again as lines, pulled toward the camera (reverse-Z: greater is nearer).
            uniforms.elevation.w = 1
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setTriangleFillMode(.lines)
            encoder.setDepthBias(0, slopeScale: 1, clamp: 0)
            draw(visible, encoder, indexCount: patches.surfaceIndexCount)
        }
        encoder.endEncoding()
    }

    private func draw(_ visible: [Patch], _ encoder: MTLRenderCommandEncoder, indexCount: Int) {
        for patch in visible {
            var skirtDepth = patch.skirtDepth
            encoder.setVertexBuffer(patch.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&skirtDepth, length: MemoryLayout<Float>.stride, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indexCount,
                indexType: .uint32,
                indexBuffer: patches.indexBuffer,
                indexBufferOffset: 0
            )
        }
    }

    /// Left, right, bottom, top, and near planes of `m`'s frustum, pointing inward and
    /// normalized (reverse-Z with an infinite far plane has no far plane).
    private static func frustumPlanes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        func row(_ r: Int) -> SIMD4<Float> { SIMD4(m[0][r], m[1][r], m[2][r], m[3][r]) }
        let (r0, r1, r2, r3) = (row(0), row(1), row(2), row(3))
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 - r2].map { $0 / length(SIMD3($0.x, $0.y, $0.z)) }
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
