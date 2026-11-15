import SwiftUI

@main
struct PlanetApp: App {
    init() {
        LaunchOptions.handleHelp()
        Benchmark.runIfRequested()
        Video.runIfRequested()
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Planet") {
            ContentView()
        }
        // Without a default size, the window would grow to fit the whole sidebar.
        .defaultSize(width: 1100, height: 700)
        .commands { InspectorCommands() }
    }
}
