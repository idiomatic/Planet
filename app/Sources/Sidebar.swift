import SwiftUI

/// The trailing sidebar (an inspector): the planet's generation parameters, the live view
/// parameters, and readouts. Generation edits wait for Generate; live edits apply at once.
struct Sidebar: View {
    @Binding var parameters: PlanetParameters
    /// The parameters of the planet on screen, if any, to tell whether edits are pending.
    let current: PlanetParameters?
    @Bindable var settings: ViewSettings
    let readouts: Readouts?
    let generate: () -> Void
    @FocusState private var seedFocused: Bool

    private var pending: Bool { current != nil && parameters != current }
    private var isEarth: Bool { parameters.regionScale == 1 && settings.values == .earth }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { parameterSections.padding() }
            Divider()
            statusSection.padding()
        }
        .onAppear { if current == nil { seedFocused = true } }
    }

    /// The planet's and the view's parameters, which scroll.
    private var parameterSections: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Planet").font(.headline)
                    Spacer()
                    Button("Reset to Earth", systemImage: "globe.europe.africa.fill") {
                        parameters.regionScale = 1
                        settings.values = .earth
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Reset to Earth (keeps the seed; region scale waits for Generate)")
                    .disabled(isEarth)
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Seed", text: $parameters.seed, prompt: Text("e.g., perihelion"))
                        .textFieldStyle(.roundedBorder)
                        .focused($seedFocused)
                        .onSubmit { if !parameters.seed.isEmpty { generate() } }
                    row("Region scale (≥ 1)", $parameters.regionScale, .logarithmic(1...100), earth: 1)
                    HStack {
                        if pending {
                            Text("Changes pending").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Generate", action: generate)
                            .keyboardShortcut(.defaultAction)
                            .disabled(parameters.seed.isEmpty || (current != nil && !pending))
                    }
                }

                Divider()
                Text("View").font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                    row("Relief (%)", $settings.values.exaggeration, .logarithmic(10...100_000, zeroAtStart: true), earth: ViewValues.earth.exaggeration)
                    row("Sea level (% of elevation range)", $settings.values.seaLevel, .linear(0...100), earth: ViewValues.earth.seaLevel)
                    row("Air density (× Earth)", $settings.values.airDensity, .logarithmic(0.01...100, zeroAtStart: true), earth: ViewValues.earth.airDensity)
                    row("Axial tilt (°)", $settings.values.axialTilt, .linear(0...90), earth: ViewValues.earth.axialTilt)
                    row("Day length (× Earth)", $settings.values.dayLength, .logarithmic(0.01...100, zeroAtStart: true), earth: ViewValues.earth.dayLength)
                    row("Year length (× Earth)", $settings.values.yearLength, .logarithmic(0.01...100, zeroAtStart: true), earth: ViewValues.earth.yearLength)
                    row("Detail (pixels; smaller is finer)", $settings.values.detail, .logarithmic(3...48), earth: ViewValues.earth.detail)
                    row("Exposure", $settings.values.exposure, .logarithmic(0.05...2), earth: ViewValues.earth.exposure)
                    row("Field of view (°)", $settings.values.fieldOfView, .linear(10...120), earth: ViewValues.earth.fieldOfView)
                    // Relief is relative to the radius, so it changes only lengths in km (readouts);
                    // shown for reference, set by --radius, until physics uses it.
                    row("Radius (% of Earth)", $settings.values.radiusScale, .logarithmic(1...1000), earth: ViewValues.earth.radiusScale)
                        .disabled(true)
                        .help("Affects only lengths in kilometers for now; set with --radius")
                }
            }
    }

    /// Readouts and the controls, pinned below the parameters so they're always visible.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let readouts {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    readout("Seed", current?.seed ?? "")
                    readout("Time", readouts.timeSpeed.formatted(.number.precision(.fractionLength(0))) + "%")
                    readout("Day", readouts.day.isNaN ? "—" : String(format: "%.2f", readouts.day))
                    readout("Altitude", readouts.altitude.formatted(.number.precision(.fractionLength(0))) + " km")
                    readout("Patches", "\(readouts.patchesDrawn) drawn, \(readouts.patchesCached) cached")
                }
                .font(.callout.monospacedDigit())
            }
            Text("""
                Drag: look · Wheel: zoom · W/S, A/D, R/F: move · Q/E: roll · Shift: faster · \
                M: mesh · B: blend · H: air off/on · [ ]: air · − =: relief · , .: time · \
                ⌃⌘I: sidebar
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A slider's range and scale. Logarithmic suits ratios; sea level (which includes 0),
    /// tilt (which can be negative), and field of view are linear.
    private enum Scale {
        /// With `zeroAtStart`, the slider's leftmost position is 0 (e.g., no air), which a
        /// logarithmic scale can't otherwise reach.
        case logarithmic(ClosedRange<Double>, zeroAtStart: Bool = false)
        case linear(ClosedRange<Double>)

        /// Where `x` falls along the slider, 0...1.
        func fraction(of x: Double) -> Double {
            switch self {
            case .logarithmic(let r, _):
                return min(max((log10(x) - log10(r.lowerBound)) / (log10(r.upperBound) - log10(r.lowerBound)), 0), 1)
            case .linear(let r):
                return min(max((x - r.lowerBound) / (r.upperBound - r.lowerBound), 0), 1)
            }
        }
    }

    /// A label and an editable number, with a slider beneath, marked with a tick at Earth's value
    /// (the default, for render settings), which snaps the slider there when clicked. The number
    /// may go beyond the slider's range; the slider then rests at its end.
    private func row(_ label: String, _ value: Binding<Double>, _ scale: Scale, earth: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                TextField(label, value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .labelsHidden()
            }
            switch scale {
            case .logarithmic(let range, let zeroAtStart):
                Slider(
                    value: Binding(
                        get: { log10(min(max(value.wrappedValue, range.lowerBound), range.upperBound)) },
                        set: {
                            value.wrappedValue = zeroAtStart && $0 <= log10(range.lowerBound) ? 0 : Self.rounded(pow(10, $0))
                        }
                    ),
                    in: log10(range.lowerBound)...log10(range.upperBound)
                )
                .controlSize(.small)
                .overlay(alignment: .bottom) { earthTick(at: scale.fraction(of: earth), value, earth) }
            case .linear(let range):
                Slider(
                    value: Binding(
                        get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                        set: { value.wrappedValue = Self.rounded($0) }
                    ),
                    in: range
                )
                .controlSize(.small)
                .overlay(alignment: .bottom) { earthTick(at: scale.fraction(of: earth), value, earth) }
            }
        }
        // Sliders don't take keyboard focus, so flying continues while dragging them.
        .focusable(false)
    }

    /// A small tick below the slider's track at `fraction` of its travel.
    private func earthTick(at fraction: Double, _ value: Binding<Double>, _ earth: Double) -> some View {
        GeometryReader { geometry in
            // The thumb's center travels inset by half its width from each end.
            let inset = Self.thumbInset
            let x = inset + (geometry.size.width - 2 * inset) * fraction
            Capsule()
                .fill(value.wrappedValue == earth ? Color.accentColor : Color.secondary)
                .frame(width: 2, height: 5)
                .padding(.horizontal, 4) // a larger click target
                .contentShape(Rectangle())
                .onTapGesture { value.wrappedValue = earth }
                .help("Earth: \(earth.formatted())")
                .position(x: x, y: geometry.size.height + 2)
        }
    }

    /// Half the width of a small slider's thumb, in points.
    private static let thumbInset: CGFloat = 7

    private func readout(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// Three significant digits, so dragging gives readable numbers.
    private static func rounded(_ x: Double) -> Double {
        guard x != 0 else { return 0 }
        let magnitude = pow(10, floor(log10(abs(x))) - 2)
        return (x / magnitude).rounded() * magnitude
    }
}
