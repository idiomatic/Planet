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
    }
}
