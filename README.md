# Uncanny Planet

A procedurally generated Earth-like planet viewer for macOS. [AGENTS.md](AGENTS.md) is the specification; [DEVELOPMENT.md](DEVELOPMENT.md) lists planned work.

## Design notes

* **Reproducible planets.** Generation is deterministic, so a seed and its parameters fully describe a planet; there's nothing to save or export.
* **Region scale.** Values above 1 exaggerate regions, simplifying the planet as seen from orbit; below 1 would be absurd in a different way, so it isn't allowed.
* **Memory.** A full 12-level icosphere has 10·4¹²+2 ≈ 168 million vertices, about 670 MB per 32-bit field, more than an 8 GB M1 can hold across all fields. So only a coarse level is stored globally, and finer levels are generated around the camera.
* **Vertex addresses.** A vertex on a shared edge or corner is reachable by several subdivision paths; picking the lowest gives it one detail value, so neighboring triangles don't crack apart.
* **Detail field.** Hashing (seed, address) alone yields uncorrelated white noise; midpoint displacement with shrinking amplitude turns it into natural-looking terrain.
* **Time.** Only human-scale phenomena change while time runs; geology is generated once.

## How it was made

Uncanny Planet was written with [Claude](https://claude.com).

## License

BSD 3-Clause; see [LICENSE](LICENSE).
