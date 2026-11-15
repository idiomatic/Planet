# Planet

Procedurally generated Earth-like planet viewer for macOS. Planned features: [DEVELOPMENT.md](DEVELOPMENT.md).

## Platform

* macOS 15+, Apple silicon (M1 baseline), Metal
* Zig 0.17+ core (generation, simulation) behind a C ABI; Swift 6 app (UI, Metal rendering)
* deterministic: same seed and parameters produce the same planet

## Build

* `zig build` builds the core, compiles the app with `swiftc -wmo`, and installs `zig-out/Planet.app`; no Xcode project
* `zig build run` runs the app; `zig build test` runs the core tests
* `-Dcoarse-level=N` sets the coarse level (default 6)

## Testing

* interactive tests run in a macOS VM with 4 GB of memory

## Layout

* [core/src/root.zig](core/src/root.zig): generation, simulation, C ABI, and tests
* [core/include/planet.h](core/include/planet.h): the C ABI, imported by Swift as a bridging header
* [app/Sources/](app/Sources/): SwiftUI app, Metal renderer, and shaders (compiled at runtime)
* [app/Info.plist](app/Info.plist): bundle metadata

## Parameters

Entered on an in-window panel (not a modal sheet, so menus such as Quit stay usable) before generation; defaults are Earth's. Each number has a slider (logarithmic for ratios, rounding to 3 significant digits; linear for sea level, 0–100, and tilt, 0–90°) beside an editable value, which may go beyond the slider's range. A globe button beside the title resets every number to Earth's, keeping the seed, and is disabled when they already are.

Generation parameters, fixed once a planet is generated:

* seed (user-provided text; a decimal number is used as is, other text is hashed with FNV-1a)
* planet radius scale (% of Earth)
* region scale (float ≥ 1, relative to Earth): larger gives fewer, larger regions, up to comically large
* sea level (% of the surface elevation range, from lowest to highest; default 55%)
* axial tilt (degrees)
* day length (relative to Earth)
* year length (relative to Earth)

Live parameters, which change only the view, so the panel and switches set their starting values and keys adjust them while flying (four steps of 2^¼ double or halve them); reopening the panel shows their current values:

* radial exaggeration (%, 1–1,000,000; `-` and `=`): changing it refits the cached patches' bounds and skirts and keeps the camera above the new floor
* air density (relative to Earth, 0–100; `[` and `]`; 0 is no atmosphere): H turns it off and back on to its last nonzero value

## Viewer

* simplified flight controls: drag to look; the scroll wheel or trackpad zooms along the view direction, by a fraction of the altitude; W/S, A/D, and R/F move; Q/E roll; Shift is faster; speed scales with altitude; the camera stays above the terrain
* time speed (%, default 360,000%, i.e., an hour per second; 0 pauses): `,` and `.` divide and multiply it by 10, stepping between 1% and 0
* M (or `--mesh on`) toggles drawing the mesh's edges over the surface; B (or `--lod-blend off`) toggles LOD blending; H turns the air off and on, `[` and `]` adjust its density, and `-` and `=` adjust the relief
* draws only when something changes: continuously while a movement key is held (up to 120 fps) or time runs (30 fps), otherwise once per change (drag, scroll, toggle, resize, or a newly generated patch); idle with time paused uses no CPU
* a status line shows seed, time speed, elapsed days, altitude, air density, and relief, with the controls, updating at most 4 times a second while drawing continuously
* no save or export; the seed and parameters reproduce a planet
* command-line switches set the parameters, initial camera, and controls (time speed), skip the panel, and generate at launch; every switch takes a value, since AppKit opens a bare argument as a file and then shows no window (defined in [app/Sources/LaunchOptions.swift](app/Sources/LaunchOptions.swift))
* `--help` or `-h` prints usage and exits; an unknown switch prints usage to stderr and exits with status 2
* `--snapshot <png>` instead renders one frame offscreen and exits
* `--video <mp4>` instead renders a looping flight offscreen and encodes it (H.264 High, BT.709, default 1920×1080, 60 fps, 120 s, 12 Mbps; `--duration`, `--fps`, `--bitrate`, `--size`), rendering at 2× and scaling down with a Lanczos filter in sRGB; the flight holds the sun still and circles the subsolar point through the highest peak (the sun ~50° from its zenith), with periodic distance, altitude, and view, so it loops seamlessly
* `--benchmark <frames>` instead renders frames offscreen (no window or vsync, default 2560×1600) from orbit to the surface, twice (cold, then warm from the cache), prints generation time, CPU time, frame times, fps, patch counts, and memory footprint, and exits

## Mesh

* icosphere at the coarse level (compile-time parameter, default 6, ~105 km edges), with per-vertex fields stored in the core
* vertex address: subdivision path (base face, then child index per level) plus corner; a vertex shared by several triangles uses its lowest address, so shared vertices agree

## Patches (view-dependent rendering)

* the renderer draws patches, not the coarse mesh: a patch is an icosphere triangle named by level (0–8), base face, and path, drawn as 4 more levels (a 256-triangle lattice), so the finest reach level 12 (~1.6 km)
* the core generates a patch as a pure, thread-safe function of the planet's parameters and its name (`pl_patch_generate`), with the coarse mesh's midpoint normalizations, so shared vertices agree bit for bit; each vertex carries direction, elevation, tangential elevation gradient (exact, by the chain rule through the noise and warp, so a vertex shades alike in every patch), a skirt flag, and the elevation and gradient the parent patch shows there (its own at points the parent shares; the average of the parent edge's ends at edge midpoints)
* each frame, selection starts at the 20 base faces, culls patches outside the frustum or behind the horizon, and refines a patch into its 4 children while its triangles would exceed 12 pixels
* patches are cached between frames (least recently used beyond 4,096 are evicted); missing ones are generated on background threads (utility priority, at most cores − 2 at once, the largest on screen first; wanted patches are recomputed each frame, so passed-by ones are never started) while their parent is drawn; snapshots and benchmarks generate synchronously
* LOD blending (geomorphing): the vertex shader blends each vertex from the parent's values to its own as the parent's triangles grow on screen from the split threshold to 1.5× it, so a patch matches its parent when it appears and is fully its own across the whole patch before it splits (ending at 2× pops, since a patch's far side lies ~15% farther than its near side); B or `--lod-blend on|off` toggles it (default on)
* skirts hang below patch edges to hide cracks where levels meet
* the vertex shader displaces radially by elevation × exaggeration (oceans flat at sea level) and derives normals from the gradient
* the status line shows patches drawn and cached; `--benchmark` reports patches drawn, visited, and generated per frame, and the cache hit rate

## Atmosphere

* single scattering, raymarched in the shaders, with Earth's Rayleigh (8 km scale height) and Mie (1.2 km, g = 0.8) coefficients, scaled by the air density parameter, up to 60 km; sunlight reaching each sample is attenuated through the air (6 steps) and blocked by the planet
* the air sees a planet whose radius is the true radius divided by the exaggeration, so its thickness keeps its proportion to the exaggerated relief while its vertical optical depth stays Earth's
* terrain: lit by sunlight through the air, a little skylight while the sun is up, and starlight; then aerial perspective (haze) along the view ray (12 steps)
* sky: a full-screen pass at the far plane, drawn after the terrain where only the background remains (32 steps), with the sun's disk; view directions come from the camera's basis and field of view, since unprojecting the near plane (~1e-6 radii away near the ground) loses precision and breaks the sky into blocks
* samples are offset per pixel by interleaved gradient noise, trading banding for fine noise; radiance is tone-mapped (1 − e^(−0.25·L))
* air density 0 (`--air 0`, or H) turns it off, rendering exactly as without it

## Elevation (placeholder until tectonics)

* domain-warped fractal value noise of the seed, 13 octaves (finest ~1 km); region scale divides its base frequency

## Orbit

* rotation (day/night), axial tilt, and orbit (seasons) give the sun's direction in the planet's frame
