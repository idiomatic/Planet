import SwiftUI

@main
struct UncannyPlanetApp: App {
    init() {
        LaunchOptions.handleHelp()
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Uncanny Planet") {
            ContentView()
        }
    }
}
