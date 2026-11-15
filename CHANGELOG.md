# Changelog

All notable changes to Planet are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-15

### Added

* Specification ([AGENTS.md](AGENTS.md)), development plan ([DEVELOPMENT.md](DEVELOPMENT.md)), and [README.md](README.md)
* Prototype: Zig core with a C ABI (coarse icosphere with vertex addresses, placeholder elevation, sun direction), and a Swift app with an in-window parameter panel, Metal globe, flight controls with scroll-wheel zoom, time speed with pause, command-line switches with `--help`, and `--snapshot`
* Mesh wireframe, toggled with M or `--mesh on`
* `--benchmark <frames>`: offscreen frame timings and memory footprint
* View-dependent rendering: patches refined by screen size down to level 12 (~1.6 km), generated in the background by the core, and cached between frames
* LOD blending (geomorphing) between patch levels, toggled with B or `--lod-blend`
* Sliders in the parameter panel, logarithmic for ratios, beside editable values
* Reset to Earth (a globe button) in the parameter panel
* `--video <mp4>`: a seamlessly looping flight, supersampled, encoded as H.264
* A two-minute demo flight in the README, over the planet Mihira, with the atmosphere and a sunset, hosted in [issue #1](https://github.com/idiomatic/Planet/issues/1)
* Atmosphere: Rayleigh and Mie single scattering for the sky, haze (aerial perspective), and sunlight through the air, with air density as a parameter (`--air`, 0 for none)
* Live parameters: air density (`[`, `]`, and H) and radial exaggeration (`-` and `=`) adjust while flying
* A trailing sidebar replaces the parameter panel: the planet's generation parameters, live view parameters (now also radius, sea level, tilt, day and year length, detail, exposure, and field of view; relief is relative to the planet's radius), readouts, and ticks at Earth's values; `--sidebar open|closed`
* CI: core tests and a release build on every push and pull request; pushing a version tag publishes a GitHub release with the zipped, ad hoc signed app

### Changed

* Renamed from Uncanny Planet to Planet (app, bundle `com.rbrian.Planet`, header `planet.h`, C ABI prefix `pl_`)
* Lower CPU use: drawing only when something changes (idle with time paused uses none), an exact elevation gradient (patch generation 3.8× faster), and patch requests ranked by screen size at utility priority
