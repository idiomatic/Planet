import SwiftUI

struct ContentView: View {
    @State private var parameters = LaunchOptions.current?.parameters ?? PlanetParameters()
    @State private var settings = ViewSettings(LaunchOptions.current?.view ?? .earth)
    @State private var renderer: Renderer?
    /// The sidebar opens by default, but not when launched with switches, unless --sidebar says.
    @State private var showingSidebar = LaunchOptions.sidebarOpen
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let renderer {
                PlanetView(renderer: renderer)
            } else {
                Text("Enter a seed and choose Generate.")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .inspector(isPresented: $showingSidebar) {
            Sidebar(
                parameters: $parameters,
                current: renderer?.planet.parameters,
                settings: settings,
                readouts: renderer?.readouts,
                generate: generate
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            Button("Sidebar", systemImage: "sidebar.trailing") { showingSidebar.toggle() }
                .help("Show or hide the sidebar (⌃⌘I)")
        }
        .alert("The planet couldn’t be generated.", isPresented: $failed) {}
        .onAppear {
            guard renderer == nil, let options = LaunchOptions.current else { return }
            generate()
            guard let renderer else { return }
            renderer.place(options.camera(for: renderer.planet))
            if let speed = options.timeSpeed { renderer.timeSpeed = speed }
            renderer.showMesh = options.showMesh
            renderer.blendLevels = options.blendLevels
        }
    }

    private func generate() {
        guard let planet = Planet(parameters), let renderer = Renderer(planet: planet, settings: settings) else {
            failed = true
            return
        }
        self.renderer = renderer
    }
}

struct PlanetView: NSViewRepresentable {
    let renderer: Renderer

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
        renderer.view = view
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        // Takes keyboard focus for flying when a planet appears; clicking it takes it again.
        view.flightFocus = true
    }
}
