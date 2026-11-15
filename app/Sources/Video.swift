import AVFoundation
import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// `--video <mp4>` renders a looping flight offscreen and encodes it as H.264, then exits.
/// Frames are rendered at twice the output size and scaled down with a Lanczos filter.
@MainActor
enum Video {
    static func runIfRequested() {
        guard let options = LaunchOptions.current, let output = options.video else { return }
        let (width, height) = options.videoSize
        let fps = options.fps
        let frames = Int((options.duration * Double(fps)).rounded())
        let supersample = 2

        guard let planet = Planet(options.parameters),
              let renderer = Renderer(planet: planet),
              let pass = renderer.offscreenPass(width: width * supersample, height: height * supersample),
              let rendered = pass.colorAttachments[0].texture,
              // The sRGB-encoded bytes as is, so scaling happens in sRGB, as video expects.
              let source = rendered.makeTextureView(pixelFormat: .bgra8Unorm),
              let queue = renderer.device.makeCommandQueue()
        else { fail("setup") }
        renderer.patches.synchronous = true
        renderer.showMesh = options.showMesh
        renderer.blendLevels = options.blendLevels
        renderer.showAtmosphere = options.showAtmosphere

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        targetDescriptor.usage = [.shaderWrite, .shaderRead]
        targetDescriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: targetDescriptor) else { fail("target") }
        let scaler = MPSImageLanczosScale(device: renderer.device)

        let url = URL(fileURLWithPath: output)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { fail("writer") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(options.bitrate * 1_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { fail("start: \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)

        let flight = LoopingFlight(planet: planet, floor: renderer.floorRadius)
        let start = Date()
        for i in 0..<frames {
            renderer.place(flight.camera(at: Double(i) / Double(frames)))
            guard renderer.renderOffscreen(pass) != nil, let commands = queue.makeCommandBuffer() else { fail("render") }
            scaler.encode(commandBuffer: commands, sourceTexture: source, destinationTexture: target)
            commands.commit()
            commands.waitUntilCompleted()

            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            guard let pool = adaptor.pixelBufferPool else { fail("pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { fail("buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            target.getBytes(
                CVPixelBufferGetBaseAddress(buffer)!,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            else { fail("append: \(writer.error?.localizedDescription ?? "")") }

            if (i + 1) % (fps * 10) == 0 || i + 1 == frames {
                let elapsed = Date().timeIntervalSince(start)
                FileHandle.standardError.write(Data(String(
                    format: "%d/%d frames, %.0f s elapsed, %d patches cached\n",
                    i + 1, frames, elapsed, renderer.patches.cachedCount
                ).utf8))
            }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { fail("finish: \(writer.error?.localizedDescription ?? "")") }
        exit(0)
    }

    private static func fail(_ step: String) -> Never {
        FileHandle.standardError.write(Data("video failed: \(step)\n".utf8))
        exit(1)
    }
}

/// A closed flight over the sunlit side, with the sun held still: the camera circles the point
/// beneath the sun, through the highest peak, while its distance from that point, its altitude,
/// and its view all vary periodically, so the last frame leads seamlessly into the first.
struct LoopingFlight {
    private let center: SIMD3<Double>
    private let e1: SIMD3<Double>
    private let e2: SIMD3<Double>
    private let radius: Double
    private let floor: Double
    private let seconds: Double

    @MainActor
    init(planet: Planet, floor: Float) {
        let elevations = planet.elevations
        let i = elevations.indices.max { elevations[$0] < elevations[$1] }!
        let p = planet.positions
        let summit = normalize(SIMD3(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2])))

        // The time of day when the sun stands 50° from the summit's zenith (or as near as it gets).
        let day = 86_400 * planet.parameters.dayLength
        let ideal = cos(50 * Double.pi / 180)
        seconds = stride(from: 0, to: day, by: day / 1440).min {
            abs(Self.sun(planet, $0, summit) - ideal) < abs(Self.sun(planet, $1, summit) - ideal)
        } ?? 0
        let s = planet.sunDirection(at: seconds)
        center = normalize(SIMD3(Double(s.x), Double(s.y), Double(s.z)))
        radius = acos(min(max(dot(center, summit), -1), 1))
        e1 = normalize(summit - center * dot(summit, center))
        e2 = cross(center, e1)
        self.floor = Double(floor)
    }

    private static func sun(_ planet: Planet, _ seconds: Double, _ point: SIMD3<Double>) -> Double {
        let s = planet.sunDirection(at: seconds)
        return dot(SIMD3(Double(s.x), Double(s.y), Double(s.z)), point)
    }

    /// The camera `u` (0...1) of the way around the loop.
    func camera(at u: Double) -> Camera {
        let position = point(u)
        // Look ahead along the path, below the camera's own altitude.
        let ahead = direction(u + 0.03) * (floor + altitude(u) * 0.15)
        return Camera(
            position: SIMD3<Float>(position),
            target: SIMD3<Float>(ahead),
            seconds: seconds
        )
    }

    private func point(_ u: Double) -> SIMD3<Double> {
        direction(u) * (floor + altitude(u))
    }

    private func direction(_ u: Double) -> SIMD3<Double> {
        let tau = 2 * Double.pi
        let around = tau * u
        let away = min(max(radius + 0.18 * sin(3 * tau * u), 0.15), 1.4)
        return center * cos(away) + (e1 * cos(around) + e2 * sin(around)) * sin(away)
    }

    /// Height above the floor, in radii: low over the summit at the start, twice around the loop.
    private func altitude(_ u: Double) -> Double {
        let low = 0.015, high = 0.22
        return low + (high - low) * (0.5 - 0.5 * cos(2 * 2 * Double.pi * u))
    }
}
