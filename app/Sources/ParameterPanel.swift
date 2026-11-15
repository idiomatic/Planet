import SwiftUI

/// The new-planet form, drawn inside the window rather than as a modal sheet so that
/// menus (e.g., Quit) stay usable while it's shown.
struct ParameterPanel: View {
    @Binding var parameters: PlanetParameters
    let canCancel: Bool
    let generate: () -> Void
    let close: () -> Void
    @FocusState private var seedFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Planet").font(.title2.bold())
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Seed")
                    TextField("Seed", text: $parameters.seed, prompt: Text("e.g., perihelion"))
                        .focused($seedFocused)
                        .gridCellColumns(2)
                }
                row("Planet radius (% of Earth)", $parameters.radiusScale, .logarithmic(1...1000))
                row("Radial exaggeration (%)", $parameters.radialExaggeration, .logarithmic(10...100_000))
                row("Region scale (≥ 1)", $parameters.regionScale, .logarithmic(1...100))
                row("Sea level (% of elevation range)", $parameters.seaLevel, .linear(0...100))
                row("Axial tilt (°)", $parameters.axialTilt, .linear(0...90))
                row("Day length (× Earth)", $parameters.dayLength, .logarithmic(0.01...100))
                row("Year length (× Earth)", $parameters.yearLength, .logarithmic(0.01...100))
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            HStack {
                Spacer()
                if canCancel {
                    Button("Cancel", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                Button("Generate") {
                    generate()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parameters.seed.isEmpty)
            }
        }
        .padding()
        .frame(width: 640)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(radius: 20)
        .onAppear { seedFocused = true }
    }

    /// A slider's range and scale. Logarithmic suits ratios; sea level (which includes 0) and
    /// tilt (which can be negative) are linear.
    private enum Scale {
        case logarithmic(ClosedRange<Double>)
        case linear(ClosedRange<Double>)
    }

    /// A label, a slider, and an editable number. The number may go beyond the slider's range;
    /// the slider then rests at its end.
    private func row(_ label: String, _ value: Binding<Double>, _ scale: Scale) -> some View {
        GridRow {
            Text(label)
            switch scale {
            case .logarithmic(let range):
                Slider(
                    value: Binding(
                        get: { log10(min(max(value.wrappedValue, range.lowerBound), range.upperBound)) },
                        set: { value.wrappedValue = Self.rounded(pow(10, $0)) }
                    ),
                    in: log10(range.lowerBound)...log10(range.upperBound)
                )
            case .linear(let range):
                Slider(
                    value: Binding(
                        get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                        set: { value.wrappedValue = Self.rounded($0) }
                    ),
                    in: range
                )
            }
            TextField(label, value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }

    /// Three significant digits, so dragging gives readable numbers.
    private static func rounded(_ x: Double) -> Double {
        guard x != 0 else { return 0 }
        let magnitude = pow(10, floor(log10(abs(x))) - 2)
        return (x / magnitude).rounded() * magnitude
    }
}
