import Foundation
import simd

struct Camera {
    var position: SIMD3<Float>
    var target: SIMD3<Float>
    var seconds: Double
}

/// Command-line switches; see `usage`. Every switch takes a value: AppKit pairs arguments as
/// `-key value`, and a leftover bare argument is opened as a file, which suppresses the window.
struct LaunchOptions {
    static let usage = """
        Usage: Planet [--switch value ...]

        Any switch opens straight to a planet, with the sidebar closed unless --sidebar open.
        Every switch takes a value.

          --sidebar <open|closed> start with the sidebar open or closed (default open
                                 without other switches, closed with them; ⌃⌘I toggles)

        Planet (generation):
          --seed <text>          seed; a decimal number is used as is (default hal9000)
          --region-scale <n>     region scale, ≥ 1 (default 1)

        View (live; the sidebar adjusts them while flying):
          --exaggeration <%>     radial exaggeration (default 100; keys -/=)
          --radius <%>           planet radius, % of Earth (default 100)
          --sea-level <%>        sea level, % of the elevation range (default 55)
          --air <× Earth>        air density (default 1; 0 for none; keys [/], H off and on)
          --tilt <degrees>       axial tilt (default 23.44)
          --day <× Earth>        day length (default 1)
          --year <× Earth>       year length (default 1)
          --detail <pixels>      refine patches whose triangles exceed this (whole pixels,
                                 2–200; default 12)
          --cache <MB>           patch cache size (whole megabytes, 8–4096; default 40,
                                 about 4,100 patches)
          --exposure <n>         exposure for the atmosphere (default 0.25)
          --fov <degrees>        vertical field of view (default 60)

        Camera:
          --direction <x,y,z>    camera direction from the center (default 0,0,1)
          --distance <radii>     camera distance from the center (default 3, or 1.04 with peak)
          --look-at <x,y,z|peak> point to look at (default 0,0,0); peak looks obliquely at
                                 the highest point, in low sun (66–76° from the zenith)
                                 unless --time is given
          --time <seconds>       simulated time since epoch (default 0)

        Controls:
          --time-speed <%>       100 is real time, 0 pauses (default 360000)
          --mesh <on|off>        draw the mesh's edges (default off; M toggles)
          --lod-blend <on|off>   blend between levels of detail (default on; B toggles)

        Snapshot:
          --snapshot <png>       render one frame to a PNG and exit, without a window
          --size <w>x<h>         snapshot, benchmark, or video size in pixels (default
                                 1280x800, 2560x1600 for a benchmark, 1920x1080 for a video)

        Benchmark:
          --benchmark <frames>   render frames offscreen (no window or vsync) from orbit to
                                 the surface, print timings and memory, and exit

        Video:
          --video <mp4>          render a looping flight over the sunlit side (through the
                                 highest peak) to an H.264 video, and exit
          --duration <seconds>   video length (default 120)
          --fps <n>              video frame rate (default 60)
          --bitrate <Mbps>       video bit rate (default 12)

          --help, -h             show this help and exit
        """

    private static let switches: Set = [
        "--seed", "--radius", "--exaggeration", "--region-scale", "--sea-level", "--tilt", "--day",
        "--year", "--air", "--direction", "--distance", "--look-at", "--time", "--time-speed", "--mesh",
        "--lod-blend", "--sidebar", "--detail", "--cache", "--exposure", "--fov", "--snapshot",
        "--size", "--benchmark", "--video", "--duration", "--fps", "--bitrate",
    ]

    /// Prints usage and exits for `--help` or `-h`, or for an unknown switch (to stderr, status 2).
    static func handleHelp() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(0)
        }
        if let unknown = arguments.first(where: { $0.hasPrefix("--") && !switches.contains($0) }) {
            FileHandle.standardError.write(Data("Unknown switch \(unknown)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }

    var parameters = PlanetParameters()
    var view = ViewValues.earth
    var timeSpeed: Double?
    var showMesh = false
    var blendLevels = true
    var snapshot: String?
    var size = [1280, 800]
    var benchmarkFrames: Int?
    private var sizeGiven = false

    var video: String?
    var duration = 120.0
    var fps = 60
    var bitrate = 12.0

    /// A benchmark defaults to a Retina-sized 1280×800-point window.
    var benchmarkSize: (Int, Int) { sizeGiven ? (size[0], size[1]) : (2560, 1600) }
    var videoSize: (Int, Int) { sizeGiven ? (size[0], size[1]) : (1920, 1080) }
    private var peak = false
    private var target: SIMD3<Float> = .zero
    private var distance: Float?
    private var direction: SIMD3<Float> = [0, 0, 1]
    private var seconds: Double?

    /// Options from this process's arguments, or nil when there are no switches (other than
    /// --sidebar).
    static let current = LaunchOptions(CommandLine.arguments.dropFirst())

    /// Whether the sidebar starts open: as --sidebar says, else open without other switches.
    static var sidebarOpen: Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let i = arguments.firstIndex(of: "--sidebar"), i + 1 < arguments.count {
            return arguments[i + 1] == "open"
        }
        return current == nil
    }

    init?(_ arguments: some Collection<String>) {
        let arguments = Array(arguments)
        guard arguments.contains(where: { $0.hasPrefix("--") }) else { return nil }
        // Only --sidebar: start as without switches (no planet yet), with the sidebar as asked.
        guard arguments.contains(where: { $0.hasPrefix("--") && $0 != "--sidebar" }) else {
            return nil
        }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        func number(_ name: String, _ assign: (Double) -> Void) {
            if let v = value(name).flatMap(Double.init) { assign(v) }
        }

        parameters.seed = value("--seed") ?? "hal9000"
        number("--region-scale") { parameters.regionScale = max($0, 1) }
        number("--radius") { view.radiusScale = $0 }
        number("--exaggeration") { view.exaggeration = $0 }
        number("--sea-level") { view.seaLevel = $0 }
        number("--tilt") { view.axialTilt = $0 }
        number("--day") { view.dayLength = $0 }
        number("--year") { view.yearLength = $0 }
        number("--air") { view.airDensity = $0 }
        number("--detail") { view.detail = $0 }
        number("--cache") { view.cacheMegabytes = $0 }
        number("--exposure") { view.exposure = $0 }
        number("--fov") { view.fieldOfView = $0 }
        view.clamp()

        timeSpeed = value("--time-speed").flatMap(Double.init)
        showMesh = value("--mesh") == "on"
        blendLevels = value("--lod-blend") != "off"
        snapshot = value("--snapshot")
        benchmarkFrames = value("--benchmark").flatMap(Int.init).map { max($0, 1) }
        video = value("--video")
        number("--duration") { duration = max($0, 1 / 60) }
        if let f = value("--fps").flatMap(Int.init) { fps = min(max(f, 1), 240) }
        number("--bitrate") { bitrate = max($0, 0.1) }
        if let s = value("--size")?.split(separator: "x").compactMap({ Int($0) }), s.count == 2 {
            size = s
            sizeGiven = true
        }
        distance = value("--distance").flatMap(Float.init)
        if let d = vector(value("--direction")) { direction = normalize(d) }
        let lookAt = value("--look-at")
        peak = lookAt == "peak"
        if let t = vector(lookAt) { target = t }
        seconds = value("--time").flatMap(Double.init)
    }

    private func vector(_ text: String?) -> SIMD3<Float>? {
        guard let v = text?.split(separator: ",").compactMap({ Float($0) }), v.count == 3 else { return nil }
        return SIMD3(v[0], v[1], v[2])
    }

    func camera(for planet: Planet) -> Camera {
        guard peak else {
            return Camera(position: direction * (distance ?? 3), target: target, seconds: seconds ?? 0)
        }
        let summit = normalize(planet.peak)
        let side = normalize(cross(summit, abs(summit.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)))
        // The first time of day when the sun stands 66–76° from the summit's zenith.
        let lowSun = view.sunTime(firstIn: 0.25...0.4, at: SIMD3<Double>(summit), samples: 288)
        return Camera(
            position: normalize(summit + side * 0.12) * (distance ?? 1.04),
            target: summit,
            seconds: seconds ?? lowSun ?? 0
        )
    }
}
