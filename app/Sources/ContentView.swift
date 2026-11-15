import SwiftUI

struct ContentView: View {
    @State private var parameters = LaunchOptions.current?.parameters ?? PlanetParameters()
    @State private var renderer: Renderer?
    @State private var showingPanel = LaunchOptions.current == nil
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let renderer {
                PlanetView(renderer: renderer, focused: !showingPanel)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(renderer.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                }
            }
            if showingPanel {
                Color.black.opacity(0.4)
                ParameterPanel(
                    parameters: $parameters,
                    canCancel: renderer != nil,
                    generate: generate,
                    close: { showingPanel = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            Button("New Planet", systemImage: "globe") { showingPanel = true }
                .disabled(showingPanel)
        }
        .alert("The planet couldn’t be generated.", isPresented: $failed) {}
        .onAppear {
            guard renderer == nil, let options = LaunchOptions.current else { return }
            generate()
            guard let renderer else { return }
            renderer.place(options.camera(for: renderer.planet))
            if let speed = options.timeSpeed { renderer.timeSpeed = speed }
            renderer.showMesh = options.showMesh
        }
    }

    private func generate() {
        guard let planet = Planet(parameters), let renderer = Renderer(planet: planet) else {
            failed = true
            return
        }
        self.renderer = renderer
    }
}

struct PlanetView: NSViewRepresentable {
    let renderer: Renderer
    /// Whether the view should take keyboard focus for flying.
    let focused: Bool

    func makeNSView(context: Context) -> FlightView {
        let view = FlightView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.clearDepth = 0
        view.preferredFramesPerSecond = 120
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FlightView, context: Context) {
        view.renderer = renderer
        view.delegate = renderer
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        view.flightFocus = focused
    }
}
