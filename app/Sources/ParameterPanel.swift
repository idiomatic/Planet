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
                }
                row("Planet radius (% of Earth)", $parameters.radiusScale)
                row("Radial exaggeration (%)", $parameters.radialExaggeration)
                row("Region scale (≥ 1)", $parameters.regionScale)
                row("Sea level (% of elevation range)", $parameters.seaLevel)
                row("Axial tilt (°)", $parameters.axialTilt)
                row("Day length (× Earth)", $parameters.dayLength)
                row("Year length (× Earth)", $parameters.yearLength)
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
        .frame(width: 460)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(radius: 20)
        .onAppear { seedFocused = true }
    }

    private func row(_ label: String, _ value: Binding<Double>) -> some View {
        GridRow {
            Text(label)
            TextField(label, value: value, format: .number)
                .multilineTextAlignment(.trailing)
        }
    }
}
