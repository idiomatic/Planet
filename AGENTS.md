# Uncanny Planet

Procedurally generated Earth-like planet viewer for macOS. Planned features: [DEVELOPMENT.md](DEVELOPMENT.md).

## Platform

* macOS 15+, Apple silicon (M1 baseline), Metal
* Zig 0.17+ core (generation, simulation) behind a C ABI; Swift 6 app (UI, Metal rendering)
* deterministic: same seed and parameters produce the same planet

## Build

* `zig build` builds the core, compiles the app with `swiftc -wmo`, and installs `zig-out/Uncanny Planet.app`; no Xcode project
* `zig build run` runs the app; `zig build test` runs the core tests
* `-Dcoarse-level=N` sets the coarse level (default 6)

## Testing

* interactive tests run in a macOS VM with 4 GB of memory

## Layout

* [core/src/root.zig](core/src/root.zig): generation, simulation, C ABI, and tests
* [core/include/uncanny.h](core/include/uncanny.h): the C ABI, imported by Swift as a bridging header
* [app/Sources/](app/Sources/): SwiftUI app, Metal renderer, and shaders (compiled at runtime)
* [app/Info.plist](app/Info.plist): bundle metadata

## Parameters

Entered on an in-window panel (not a modal sheet, so menus such as Quit stay usable) before generation; defaults are Earth's.

* seed (user-provided text; a decimal number is used as is, other text is hashed with FNV-1a)
* planet radius scale (% of Earth)
* radial exaggeration (%, display only)
* region scale (float ≥ 1, relative to Earth): larger gives fewer, larger regions, up to comically large
* sea level (% of the surface elevation range, from lowest to highest; default 55%)
* axial tilt (degrees)
* day length (relative to Earth)
* year length (relative to Earth)

## Viewer

* simplified flight controls: drag to look; the scroll wheel or trackpad zooms along the view direction, by a fraction of the altitude; W/S, A/D, and R/F move; Q/E roll; Shift is faster; speed scales with altitude; the camera stays above the terrain
* time speed (%, default 360,000%, i.e., an hour per second; 0 pauses): `,` and `.` divide and multiply it by 10, stepping between 1% and 0
* M (or `--mesh on`) toggles drawing the mesh's edges over the surface
* a status line shows seed, time speed, elapsed days, and altitude, with the controls
* no save or export; the seed and parameters reproduce a planet
* command-line switches set the parameters, initial camera, and controls (time speed), skip the panel, and generate at launch; every switch takes a value, since AppKit opens a bare argument as a file and then shows no window (defined in [app/Sources/LaunchOptions.swift](app/Sources/LaunchOptions.swift))
* `--help` or `-h` prints usage and exits; an unknown switch prints usage to stderr and exits with status 2
* `--snapshot <png>` instead renders one frame offscreen and exits
* `--benchmark <frames>` instead renders frames offscreen (no window or vsync, default 2560×1600) from orbit to the surface, prints generation time, frame times, fps, and memory footprint, and exits

## Mesh

* icosphere at the coarse level (compile-time parameter, default 6, ~105 km edges), with per-vertex fields stored in the core
* vertex address: subdivision path (base face, then child index per level) plus corner; a vertex shared by several triangles uses its lowest address, so shared vertices agree
* rendering displaces vertices radially by elevation × exaggeration, flattening oceans to sea level

## Elevation (placeholder until tectonics)

* domain-warped fractal value noise of the seed; region scale divides its base frequency

## Orbit

* rotation (day/night), axial tilt, and orbit (seasons) give the sun's direction in the planet's frame
