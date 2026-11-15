import SwiftUI

@main
struct UncannyPlanetApp: App {
    init() {
        LaunchOptions.handleHelp()
        Benchmark.runIfRequested()
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Uncanny Planet") {
            ContentView()
        }
    }
}
