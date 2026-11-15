import Darwin
import Foundation
import Metal
import simd

/// `--benchmark <frames>` renders frames offscreen, without a window or vsync, along a fixed
/// path from orbit down to the surface, twice: cold (generating patches as needed) and warm
/// (from the cache). It prints generation time, frame times, patch counts, and memory, and exits.
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
        renderer.blendLevels = options.blendLevels
        renderer.patches.synchronous = true
        let afterRenderer = Memory.now()

        print("""
            vertices (coarse)   \(planet.vertexCount)
            size                \(width)x\(height)
            mesh                \(options.showMesh ? "on" : "off")
            frames              \(frames) per pass
            generation          \(ms(generation)) (coarse mesh and root patches)
            """)
        for name in ["cold", "warm"] {
            let generated = renderer.patches.generationSeconds
            let cpuStart = cpuSeconds()
            var wall = [Double]()
            var gpu = [Double]()
            var drawn = 0
            var created = 0
            var visited = 0
            var cachedOnly = [Double]()
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
                drawn += renderer.patches.drawn
                created += renderer.patches.generatedThisFrame
                visited += renderer.patches.visited
                if renderer.patches.generatedThisFrame == 0 { cachedOnly.append(wall.last!) }
            }
            let cpu = cpuSeconds() - cpuStart
            let sorted = wall.sorted()
            let mean = wall.reduce(0, +) / Double(wall.count)
            print("""
                \(name) pass
                  CPU time          \(ms(cpu)) (\(ms(cpu / Double(frames))) per frame)
                  frame (CPU+GPU)   mean \(ms(mean)), p50 \(ms(sorted[wall.count / 2])), \
                p99 \(ms(sorted[min(wall.count - 1, wall.count * 99 / 100)]))
                  frame (GPU)       mean \(ms(gpu.reduce(0, +) / Double(gpu.count)))
                  fps (unsynced)    \(String(format: "%.0f", 1 / mean))
                  frames from cache \(cachedOnly.count), mean \
                \(ms(cachedOnly.isEmpty ? 0 : cachedOnly.reduce(0, +) / Double(cachedOnly.count)))
                  patches           \(drawn / frames) drawn and \(visited / frames) visited per frame; \
                \(created) generated (\(ms(renderer.patches.generationSeconds - generated)), \
                \(ms((renderer.patches.generationSeconds - generated) / Double(max(created, 1)))) each); \
                hit rate \(String(format: "%.1f%%", 100 * Double(visited - created) / Double(max(visited, 1)))); \
                \(renderer.patches.cachedCount) cached
                """)
        }
        let after = Memory.now()
        print("""
            footprint           baseline \(mb(baseline.current)), +core \(mb(afterCore.current - baseline.current)), \
            +renderer \(mb(afterRenderer.current - afterCore.current)), \
            +frames \(mb(after.current &- afterRenderer.current)), peak \(mb(after.peak))
            """)
        exit(0)
    }

    private static func ms(_ s: Double) -> String { String(format: "%.3f ms", s * 1000) }

    /// User and system CPU time of this process, across all threads.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
    private static func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }

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
