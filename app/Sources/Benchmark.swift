import Darwin
import Foundation
import Metal
import simd

/// `--benchmark <frames>` renders frames offscreen, without a window or vsync, along a fixed
/// path from orbit down to the surface, then prints generation time, frame times, and memory,
/// and exits.
@MainActor
enum Benchmark {
    static func runIfRequested() {
        guard let options = LaunchOptions.current, let frames = options.benchmarkFrames else { return }
        let (width, height) = options.benchmarkSize

        let baseline = Memory.now()
        let start = Date()
        guard let planet = Planet(options.parameters) else { fail() }
        let generation = Date().timeIntervalSince(start)
        let afterCore = Memory.now()
        guard let renderer = Renderer(planet: planet),
              let pass = renderer.offscreenPass(width: width, height: height)
        else { fail() }
        renderer.showMesh = options.showMesh
        let afterRenderer = Memory.now()

        var gpu = [Double]()
        var wall = [Double]()
        for i in 0..<frames {
            // Circle the planet while descending from 3 radii to just above the floor.
            let t = Float(i) / Float(max(frames - 1, 1))
            let angle = t * 2 * .pi
            let distance = 3 - t * 1.98
            renderer.place(Camera(
                position: SIMD3(sin(angle), 0.3, cos(angle)) * distance / length(SIMD3<Float>(1, 0.3, 0)),
                target: .zero,
                seconds: Double(i) * 3600
            ))
            let frameStart = Date()
            guard let commands = renderer.renderOffscreen(pass) else { fail() }
            wall.append(Date().timeIntervalSince(frameStart))
            gpu.append(commands.gpuEndTime - commands.gpuStartTime)
        }
        let afterFrames = Memory.now()

        func ms(_ s: Double) -> String { String(format: "%.3f ms", s * 1000) }
        func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        let sortedWall = wall.sorted()
        let meanWall = wall.reduce(0, +) / Double(wall.count)
        let meanGPU = gpu.reduce(0, +) / Double(gpu.count)
        print("""
            vertices            \(planet.vertexCount)
            triangles           \(planet.indices.count / 3)
            size                \(width)x\(height)
            mesh                \(options.showMesh ? "on" : "off")
            frames              \(frames)
            generation          \(ms(generation))
            frame (CPU+GPU)     mean \(ms(meanWall)), p50 \(ms(sortedWall[wall.count / 2])), \
            p99 \(ms(sortedWall[min(wall.count - 1, wall.count * 99 / 100)]))
            frame (GPU)         mean \(ms(meanGPU))
            fps (unsynced)      \(String(format: "%.0f", 1 / meanWall))
            footprint           baseline \(mb(baseline.current)), +core \(mb(afterCore.current - baseline.current)), \
            +renderer \(mb(afterRenderer.current - afterCore.current)), \
            +frames \(mb(afterFrames.current &- afterRenderer.current)), peak \(mb(afterFrames.peak))
            """)
        exit(0)
    }

    private static func fail() -> Never {
        FileHandle.standardError.write(Data("benchmark failed\n".utf8))
        exit(1)
    }
}

/// Physical footprint of this process, as Activity Monitor's Memory column reports it.
private struct Memory {
    var current: UInt64
    var peak: UInt64

    static func now() -> Memory {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return Memory(current: 0, peak: 0) }
        return Memory(current: info.ri_phys_footprint, peak: info.ri_lifetime_max_phys_footprint)
    }
}
