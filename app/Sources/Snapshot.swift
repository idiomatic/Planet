import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders one frame offscreen to the PNG named by `--snapshot`, then exits.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        guard let options = LaunchOptions.current, let output = options.snapshot else { return }
        guard let planet = Planet(options.parameters),
              let renderer = Renderer(planet: planet)
        else { fail() }
        renderer.place(options.camera(for: planet))
        guard let image = renderer.snapshot(width: options.size[0], height: options.size[1]),
              let destination = CGImageDestinationCreateWithURL(
                  URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { fail() }
        CGImageDestinationAddImage(destination, image, nil)
        exit(CGImageDestinationFinalize(destination) ? 0 : 1)
    }

    private static func fail() -> Never {
        FileHandle.standardError.write(Data("snapshot failed\n".utf8))
        exit(1)
    }
}
