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
        Usage: Uncanny Planet [--switch value ...]

        Any switch skips the parameter panel and opens straight to a planet.
        Every switch takes a value.

        Planet:
          --seed <text>          seed; a decimal number is used as is (default hal9000)
          --radius <%>           planet radius, % of Earth (default 100)
          --exaggeration <%>     radial exaggeration, display only (default 100)
          --region-scale <n>     region scale, ≥ 1 (default 1)
          --sea-level <%>        sea level, % of the elevation range (default 55)
          --tilt <degrees>       axial tilt (default 23.44)
          --day <× Earth>        day length (default 1)
          --year <× Earth>       year length (default 1)

        Camera:
          --direction <x,y,z>    camera direction from the center (default 0,0,1)
          --distance <radii>     camera distance from the center (default 3, or 1.04 with peak)
          --look-at <x,y,z|peak> point to look at (default 0,0,0); peak looks obliquely at
                                 the highest point, in morning light unless --time is given
          --time <seconds>       simulated time since epoch (default 0)

        Controls:
          --time-speed <%>       100 is real time, 0 pauses (default 360000)
          --mesh <on|off>        draw the mesh's edges (default off; M toggles)

        Snapshot:
          --snapshot <png>       render one frame to a PNG and exit, without a window
          --size <w>x<h>         snapshot size in pixels (default 1280x800)

          --help, -h             show this help and exit
        """

    private static let switches: Set = [
        "--seed", "--radius", "--exaggeration", "--region-scale", "--sea-level", "--tilt", "--day",
        "--year", "--direction", "--distance", "--look-at", "--time", "--time-speed", "--mesh", "--snapshot",
        "--size",
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
    var timeSpeed: Double?
    var showMesh = false
    var snapshot: String?
    var size = [1280, 800]
    private var peak = false
    private var target: SIMD3<Float> = .zero
    private var distance: Float?
    private var direction: SIMD3<Float> = [0, 0, 1]
    private var seconds: Double?

    /// Options from this process's arguments, or nil when there are no switches.
    static let current = LaunchOptions(CommandLine.arguments.dropFirst())

    init?(_ arguments: some Collection<String>) {
        let arguments = Array(arguments)
        guard arguments.contains(where: { $0.hasPrefix("--") }) else { return nil }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        func number(_ name: String, _ assign: (Double) -> Void) {
            if let v = value(name).flatMap(Double.init) { assign(v) }
        }

        parameters.seed = value("--seed") ?? "hal9000"
        number("--radius") { parameters.radiusScale = $0 }
        number("--exaggeration") { parameters.radialExaggeration = $0 }
        number("--region-scale") { parameters.regionScale = $0 }
        number("--sea-level") { parameters.seaLevel = $0 }
        number("--tilt") { parameters.axialTilt = $0 }
        number("--day") { parameters.dayLength = $0 }
        number("--year") { parameters.yearLength = $0 }

        timeSpeed = value("--time-speed").flatMap(Double.init)
        showMesh = value("--mesh") == "on"
        snapshot = value("--snapshot")
        if let s = value("--size")?.split(separator: "x").compactMap({ Int($0) }), s.count == 2 { size = s }
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
        let elevations = planet.elevations
        let i = elevations.indices.max { elevations[$0] < elevations[$1] }!
        let p = planet.positions
        let summit = normalize(SIMD3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]))
        let side = normalize(cross(summit, abs(summit.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)))
        let day = 86_400 * planet.parameters.dayLength
        let morning = stride(from: 0, to: day, by: day / 288).first {
            (0.25...0.4).contains(dot(planet.sunDirection(at: $0), summit))
        }
        return Camera(
            position: normalize(summit + side * 0.12) * (distance ?? 1.04),
            target: summit,
            seconds: seconds ?? morning ?? 0
        )
    }
}
