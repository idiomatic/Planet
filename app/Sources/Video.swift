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
              let renderer = Renderer.offscreen(options, planet: planet),
              let pass = renderer.offscreenPass(width: width * supersample, height: height * supersample),
              let rendered = pass.colorAttachments[0].texture,
              // The sRGB-encoded bytes as is, so scaling happens in sRGB, as video expects.
              let source = rendered.makeTextureView(pixelFormat: .bgra8Unorm),
              let queue = renderer.device.makeCommandQueue()
        else { fail("setup") }

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

        let flight = LoopingFlight(planet: planet, view: options.view, floor: renderer.floorRadius)
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
/// and its view all vary periodically, so the last frame leads seamlessly into the first. Halfway
/// round, it swings out until the sun stands just above the visible horizon, past the terminator
/// (the ground below falls into dusk), and turns toward it.
struct LoopingFlight {
    private let center: SIMD3<Double>
    private let e1: SIMD3<Double>
    private let e2: SIMD3<Double>
    private let radius: Double
    private let floor: Double
    private let seconds: Double
    /// How far below the horizontal the horizon lies at the sunset, seen from its low altitude.
    private let dip: Double

    @MainActor
    init(planet: Planet, view: ViewValues, floor: Float) {
        let summit = normalize(SIMD3<Double>(planet.peak))

        // The time of day when the sun stands 50° from the summit's zenith (or as near as it gets).
        seconds = view.sunTime(nearest: cos(50 * Double.pi / 180), at: summit, samples: 1440) ?? 0
        let s = view.sunDirection(at: seconds)
        center = normalize(SIMD3(Double(s.x), Double(s.y), Double(s.z)))
        radius = acos(min(max(dot(center, summit), -1), 1))
        e1 = normalize(summit - center * dot(summit, center))
        e2 = cross(center, e1)
        self.floor = Double(floor)
        dip = acos(1 / (Double(floor) + Self.low))
    }

    /// How far the loop has swung out toward the low sun: 0 at the summit, 1 halfway round.
    private static func sunset(_ u: Double) -> Double {
        pow(0.5 - 0.5 * cos(2 * Double.pi * u), 3)
    }

    /// The camera `u` (0...1) of the way around the loop.
    func camera(at u: Double) -> Camera {
        let position = point(u)
        // Look ahead along the path, below the camera's own altitude...
        let ahead = normalize(direction(u + 0.03) * (floor + altitude(u) * 0.15) - position)
        // ...turning, near the low sun, toward it, a little below the horizon.
        let up = normalize(position)
        // Pitched to the horizon, then up a little, so the sun sits above the frame's center.
        let pitch = dip - 0.1
        let sunward = normalize(center - up * dot(center, up)) * cos(pitch) - up * sin(pitch)
        let w = pow(Self.sunset(u), 2)
        let look = normalize(ahead * (1 - w) + sunward * w)
        return Camera(
            position: SIMD3<Float>(position),
            target: SIMD3<Float>(position + look),
            seconds: seconds
        )
    }

    private func point(_ u: Double) -> SIMD3<Double> {
        direction(u) * (floor + altitude(u))
    }

    private func direction(_ u: Double) -> SIMD3<Double> {
        let tau = 2 * Double.pi
        let around = tau * u
        // The distance from beneath the sun swings ±0.12 radians, and out halfway round until the
        // sun stands 3° above the visible horizon.
        let far = (90 - 3) * Double.pi / 180 + dip
        let wiggle = min(max(radius + 0.12 * sin(3 * tau * u), 0.15), far)
        let away = wiggle + (far - wiggle) * Self.sunset(u)
        return center * cos(away) + (e1 * cos(around) + e2 * sin(around)) * sin(away)
    }

    private static let low = 0.015

    /// Height above the floor, in radii: low over the summit at the start, twice around the loop.
    private func altitude(_ u: Double) -> Double {
        let low = Self.low, high = 0.22
        return low + (high - low) * (0.5 - 0.5 * cos(2 * 2 * Double.pi * u))
    }
}
