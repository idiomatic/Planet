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

## Releases

* the version is `CFBundleShortVersionString` in [app/Info.plist](app/Info.plist) (0.1.0)
* CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the core tests and a release build on every push to main and pull request that changes more than documentation (Markdown, `docs/`, LICENSE), on Apple silicon
* pushing a tag `vX.Y.Z` runs [.github/workflows/release.yml](.github/workflows/release.yml): it fails unless the tag matches the version and [CHANGELOG.md](CHANGELOG.md) has a section for it; it tests, builds a release, signs the bundle ad hoc (the linker signs only the executable, leaving Info.plist unsealed), zips it as `Planet-X.Y.Z-macos-arm64.zip`, and publishes a GitHub release with that section as its notes
* not notarized, so downloaded copies are quarantined (the README explains opening them)

## Testing

* interactive tests run in a macOS VM with 4 GB of memory

## Layout

* [core/src/root.zig](core/src/root.zig): generation, simulation, C ABI, and tests
* [core/src/lod.zig](core/src/lod.zig): level of detail (patch selection and the cache's bookkeeping) and its tests
* [core/include/planet.h](core/include/planet.h): the C ABI, imported by Swift as a bridging header; its planet parameters (`pl_params`) are exactly the generation parameters, and everything live stays in the app
* [app/Sources/](app/Sources/): SwiftUI app, Metal renderer, and shaders (compiled at runtime)
* [app/Info.plist](app/Info.plist): bundle metadata

## Parameters

Set in a trailing sidebar (an inspector; a toolbar button or ⌃⌘I shows and hides it), open by default, closed when launched with switches, either as `--sidebar open|closed` says. Defaults are Earth's. Each number has an editable value beside its label and a slider beneath (logarithmic for ratios, rounding to 3 significant digits; linear for sea level, tilt, and field of view), with a tick at Earth's value (the default, for render settings) that snaps the slider there when clicked and is accented while the value matches; the value may go beyond the slider's range. A globe button resets every parameter to Earth's, keeping the seed. The sidebar's bottom, pinned below the scrolling parameters, shows readouts (seed, time speed, day, altitude above sea level, patches drawn and cached, with the cache's megabytes) and the controls.

Generation parameters (the sidebar's Planet section), applied by Generate or Return in the seed field; edits are marked pending until then:

* seed (user-provided text; a decimal number is used as is, other text is hashed with FNV-1a)
* region scale (float ≥ 1, relative to Earth): larger gives fewer, larger regions, up to comically large

Live parameters (the View section), which change only the view, so they apply as they change, and switches set their starting values; they persist across generated planets:

* radial exaggeration (whole percent, 0–1,000,000; keys `-` and `=`, four steps of 2^¼ doubling or halving, `=` from 0 going to 10%), relative to the planet's own radius: 100% gives Earth's proportions at any size, 0 a smooth ball
* sea level (% of the surface elevation range, from lowest to highest; default 55%; the slider steps whole percents, but typed fractions are kept)
* air density (relative to Earth, 0–100; keys `[` and `]`; 0 is no atmosphere): H turns it off and back on to its last nonzero value; its logarithmic slider (0.01–100) reaches 0 at its leftmost position, as relief's, day length's, and year length's do (region scale, detail, and exposure have no meaningful 0)
* axial tilt (degrees), day length and year length (relative to Earth; 0 is no spin, so the sun holds still in the sky, or no orbit, so no seasons; with day length 0 the day readout shows —): the sun's direction is a pure function of these and time (`pl_sun_direction`)
* detail (whole pixels, 2–200; default 12): patches are refined while their triangles exceed it; its logarithmic slider (3–48) rounds to whole pixels
* patch cache (whole megabytes, 8–4,096; default 40, about 4,100 patches; `--cache`): its logarithmic slider (16–1,024) rounds to whole megabytes; shrinking it evicts on the next frame, never patches in use
* exposure (default 0.25) and vertical field of view (whole degrees, 5–150; default 60)
* planet radius (whole percent of Earth, 1–100,000; last, and disabled in the sidebar, so set only by `--radius`): the core's Earth-scale elevations scale with it, so it changes only lengths in kilometers (readouts), not the view

The core turns relief and sea level into the surface as shown (`pl_planet_surface`): radii per meter of elevation, sea level in meters, the global floor (above the highest peak, for the demo's flight), and the planet radius and top the air sees; and the ground in any direction (`pl_planet_ground_at`). Exaggeration and sea level move the surface, so changing them refits the cached patches' bounds and skirts and keeps the camera above the new floor; the rest only redraw. The live values are one observed model (`ViewSettings`) that the sidebar binds to, the keys change, and the renderer watches and clamps (not in a `didSet`, which under `@Observable` recurses).

## Viewer

* simplified flight controls: drag to look; the scroll wheel or trackpad zooms along the view direction, by a fraction of the altitude; W/S, A/D, and R/F move; Q/E roll; Shift is faster; speed scales with altitude above the ground under the camera (at least ~13 m, so at the floor it's 20 m/s at Earth's relief); the camera stays 20 m (of elevation, so scaled by the relief) above the ground under it, which covers the finest patches' departure from the elevation between vertices (not a coarser parent's, drawn while they generate); the near plane is 2% of the altitude, for slopes rising ahead
* time speed (%, default 360,000%, i.e., an hour per second; 0 pauses): `,` and `.` divide and multiply it by 10, stepping between 1% and 0; Space pauses and resumes at the last nonzero speed
* M (or `--mesh on`) toggles drawing the mesh's edges over the surface; B (or `--lod-blend off`) toggles LOD blending; H turns the air off and on, `[` and `]` adjust its density, and `-` and `=` adjust the relief
* draws only when something changes: continuously while a movement key is held (up to 120 fps) or time runs (30 fps), otherwise once per change (drag, scroll, toggle, resize, or a newly generated patch); idle with time paused uses no CPU
* readouts update at most 4 times a second while drawing continuously
* no save or export; the seed and parameters reproduce a planet
* command-line switches set the parameters, initial camera, and controls (time speed), and generate at launch; every switch takes a value, since AppKit opens a bare argument as a file and then shows no window (defined in [app/Sources/LaunchOptions.swift](app/Sources/LaunchOptions.swift))
* `--help` or `-h` prints usage and exits; an unknown switch prints usage to stderr and exits with status 2
* `--snapshot <png>` instead renders one frame offscreen and exits
* `--video <mp4>` instead renders a looping flight offscreen and encodes it (H.264 High, BT.709, default 1920×1080, 60 fps, 120 s, 12 Mbps; `--duration`, `--fps`, `--bitrate`, `--size`), rendering at 2× and scaling down with a Lanczos filter in sRGB; the flight holds the sun still and circles the subsolar point through the highest peak (the sun ~50° from its zenith), with periodic distance, altitude, and view, so it loops seamlessly
* the offscreen modes (snapshot, video, benchmark) generate synchronously, and the video and benchmark loops drain an autorelease pool each frame, since they never return to the run loop (otherwise evicted patches' buffers pile up)
* `--benchmark <frames>` instead renders frames offscreen (no window or vsync, default 2560×1600) from orbit to the surface, twice (cold, then warm from the cache), prints generation time, CPU time, frame times, fps, patch counts, and memory footprint, and exits

## Mesh

* icosphere at the coarse level (compile-time parameter, default 6, ~105 km edges), with per-vertex fields stored in the core
* vertex address: subdivision path (base face, then child index per level) plus corner; a vertex shared by several triangles uses its lowest address, so shared vertices agree

## Patches (view-dependent rendering)

* the renderer draws patches, not the coarse mesh: a patch is an icosphere triangle named by level (0–12), base face, and path, drawn as 4 more levels (a 256-triangle lattice), so the finest reach level 16 (~100 m)
* the core generates a patch as a pure, thread-safe function of the planet's parameters and its name (`pl_patch_generate`), with the coarse mesh's midpoint normalizations, so shared vertices agree bit for bit; each vertex carries direction, elevation, tangential elevation gradient (exact, by the chain rule through the noise and warp, so a vertex shades alike in every patch), a skirt flag, and the elevation and gradient the parent patch shows there (its own at points the parent shares; the average of the parent edge's ends at edge midpoints); given the parent's vertices, it copies the points they share (every other lattice point, 45 of 153) instead of computing them, with the same result for about 30% less work (the app copies the parent's at request time, since it may be evicted before a background task runs)
* selection, the cache's bookkeeping, the base patches, and synchronous generation (with its timing) are the core's (`pl_lod_*`, not thread-safe); the app lends a Metal buffer per slot through two callbacks (acquire, release) made only during the core's calls on the main thread, generates the patches the core requests in background tasks at utility priority (so macOS can schedule them on efficiency cores), installs them as they arrive (copied in), and draws what the core selects
* each frame, selection starts at the 20 base faces, culls patches outside the frustum or behind the horizon, and refines a patch into its 4 children while its triangles would exceed 12 pixels
* patches are cached between frames (least recently used beyond the patch cache setting are evicted; a new patch, and the arrived children of a parent still waiting for their siblings, count as used, or a full cache would evict them first and the parent would never refine); missing ones are generated on background threads (utility priority, at most cores − 2 at once, the largest on screen first; wanted patches are recomputed each frame, so passed-by ones are never started) while their parent is drawn; snapshots and benchmarks generate synchronously
* LOD blending (geomorphing): the vertex shader blends each vertex from the parent's values to its own as the parent's triangles grow on screen from the split threshold to 1.5× it, so a patch matches its parent when it appears and is fully its own across the whole patch before it splits (ending at 2× pops, since a patch's far side lies ~15% farther than its near side); B or `--lod-blend on|off` toggles it (default on)
* skirts hang below patch edges to hide cracks where levels meet
* the vertex shader displaces radially by elevation × exaggeration (oceans flat at sea level) and derives normals from the gradient
* the sidebar's readouts show patches drawn and cached (and the cache's megabytes); `--benchmark` reports patches drawn, visited, and generated per frame, and the cache hit rate

## Atmosphere

* single scattering, raymarched in the shaders, with Earth's Rayleigh (8 km scale height) and Mie (1.2 km, g = 0.8) coefficients, scaled by the air density parameter, up to 60 km; sunlight reaching each sample is attenuated through the air, looked up in a transmittance table (optical depth by height and sun angle, Bruneton's mapping, 256×64, integrated in 64 steps by a compute kernel and rebuilt when relief changes the radius the air sees; optical depth rather than transmittance, so air density scales it without a rebuild), and blocked by the planet
* the air sees a planet whose radius is the true radius divided by the exaggeration (taken as at least 100%), so above Earth's relief its thickness keeps its proportion to the exaggerated relief while its vertical optical depth stays Earth's; below it, flattening the terrain leaves Earth's air, which also keeps the air thick enough in radii for single-precision heights near radius 1
* terrain: lit by sunlight through the air, a little skylight while the sun is up, and starlight; then aerial perspective (haze) along the view ray (12 steps)
* sky: a full-screen pass at the far plane, drawn after the terrain where only the background remains (32 steps), with the sun's disk; view directions come from the camera's basis and field of view, since unprojecting the near plane (~1e-6 radii away near the ground) loses precision and breaks the sky into blocks
* samples are offset per pixel by interleaved gradient noise, trading banding for fine noise; radiance is tone-mapped (1 − e^(−0.25·L))
* air density 0 (`--air 0`, or H) turns it off, rendering exactly as without it

## Elevation (placeholder until tectonics)

* domain-warped fractal value noise of the seed, 17 octaves (finest ~60 m; the same at every level, so shared vertices agree and the gradient stays exact); region scale divides its base frequency

## Orbit

* rotation (day/night), axial tilt, and orbit (seasons) give the sun's direction in the planet's frame
* the core finds the highest coarse vertex (`pl_planet_peak`) and the time of day when the sun stands at a given angle over a point, the earliest in a range or the nearest (`pl_sun_time_first`, `pl_sun_time_nearest`), for `--look-at peak` and the demo's flight; without spin there's none
