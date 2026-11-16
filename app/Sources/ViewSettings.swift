import Foundation
import Observation
import simd

/// Live parameters and render settings: they change only the view, so they can change while
/// flying. Percentages are in percent; defaults are Earth's.
struct ViewValues: Equatable {
    /// Radial exaggeration (%), relative to the planet's radius: 100% is Earth's proportions;
    /// 0 is a smooth ball.
    var exaggeration = 100.0
    /// Planet radius (% of Earth). Relief scales with it, so it changes only lengths in km.
    var radiusScale = 100.0
    /// Sea level (% of the surface elevation range, from lowest to highest).
    var seaLevel = 55.0
    /// Air density (× Earth); 0 is no atmosphere.
    var airDensity = 1.0
    /// Axial tilt (degrees).
    var axialTilt = 23.44
    /// Day length (× Earth).
    var dayLength = 1.0
    /// Year length (× Earth).
    var yearLength = 1.0
    /// Detail: the triangle edge, in whole pixels, above which a patch is refined.
    var detail = 12.0
    /// Exposure for the atmosphere's tone mapping.
    var exposure = 0.25
    /// Vertical field of view (degrees).
    var fieldOfView = 60.0
    /// Patch cache size, in whole megabytes (10⁶ bytes); 40 holds about 4,100 patches.
    var cacheMegabytes = 40.0

    static let earth = ViewValues()

    /// Ranges the values are clamped to.
    mutating func clamp() {
        exaggeration = min(max(exaggeration.rounded(), 0), 1_000_000) // whole percent
        radiusScale = min(max(radiusScale.rounded(), 1), 100_000) // whole percent
        seaLevel = min(max(seaLevel, 0), 100)
        airDensity = min(max(airDensity, 0), 100)
        axialTilt = min(max(axialTilt, -180), 180)
        dayLength = max(dayLength, 0) // 0: no spin
        yearLength = max(yearLength, 0) // 0: no orbit
        detail = min(max(detail.rounded(), 2), 200) // whole pixels
        exposure = min(max(exposure, 0.01), 10)
        fieldOfView = min(max(fieldOfView.rounded(), 5), 150) // whole degrees
        cacheMegabytes = min(max(cacheMegabytes.rounded(), 8), 4096) // whole megabytes
    }

    /// The planet's radius, in meters.
    var radius: Double { 6_371_000 * radiusScale / 100 }

    /// The unit vector toward the sun in the planet's frame, `seconds` after epoch.
    func sunDirection(at seconds: Double) -> SIMD3<Float> {
        var out: (Float, Float, Float) = (0, 0, 0)
        withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: Float.self, capacity: 3) {
                pl_sun_direction(axialTilt, dayLength, yearLength, seconds, $0)
            }
        }
        return SIMD3(out.0, out.1, out.2)
    }

    /// The earliest of `samples` times through the first day when the cosine of the sun's angle
    /// from `point`'s zenith lies in `range`, or nil (no spin, or never in range).
    func sunTime(firstIn range: ClosedRange<Double>, at point: SIMD3<Double>, samples: UInt32) -> Double? {
        var seconds = 0.0
        var p = [point.x, point.y, point.z]
        let found = pl_sun_time_first(
            axialTilt, dayLength, yearLength, &p, range.lowerBound, range.upperBound, samples, &seconds)
        return found ? seconds : nil
    }

    /// The one of `samples` times through the first day when that cosine is nearest `target`.
    func sunTime(nearest target: Double, at point: SIMD3<Double>, samples: UInt32) -> Double? {
        var seconds = 0.0
        var p = [point.x, point.y, point.z]
        return pl_sun_time_nearest(axialTilt, dayLength, yearLength, &p, target, samples, &seconds) ? seconds : nil
    }
}

/// The live values, shared by the sidebar (which binds to them), the keys, and the renderer
/// (which observes them, and clamps them). No `didSet` here: under `@Observable`, assigning a
/// property inside its own observer goes back through the setter and recurses without end.
@MainActor
@Observable
final class ViewSettings {
    var values: ViewValues
    /// The density H restores after turning the air off.
    @ObservationIgnored var lastAirDensity: Double

    init(_ values: ViewValues = .earth) {
        var values = values
        values.clamp()
        self.values = values
        self.lastAirDensity = values.airDensity > 0 ? values.airDensity : 1
    }
}

/// Readouts for the sidebar, updated by the renderer.
@MainActor
@Observable
final class Readouts {
    var timeSpeed = 0.0
    var day = 0.0
    var altitude = 0.0 // km
    var patchesDrawn = 0
    var patchesCached = 0
    var cachedMegabytes = 0.0
}
