# Uncanny Planet

Procedurally generated Earth-like planet viewer for macOS. Planned features: [DEVELOPMENT.md](DEVELOPMENT.md).

## Platform

* macOS 15+, Apple silicon (M1 baseline), Metal
* Zig 0.17+ core (generation, simulation) behind a C ABI; Zig build; Swift app (UI, Metal rendering)
* deterministic: same seed and parameters produce the same planet
