# Development

## Pipeline

* stages run in order: orbit → tectonics → terrain → air → climate → hydrology → biome
* everything is generated once and static, except human-scale phenomena (e.g., day/night, seasons, weather), which change while time runs
* functional at stage boundaries: each stage is a pure function of its upstream outputs and its own parameters, returning new immutable output in its own arena; internals may be imperative (e.g., hydrology's fills and flow accumulation)
* each stage declares the parameters it reads, so a change reruns only that stage and its downstream
* time-varying phenomena are pure functions of the static world and time, not integrated state, so what's shown at a given time is independent of time-speed history and frame rate, and time can be scrubbed; weather is procedural noise advected by prevailing winds, with time as a noise coordinate (no emergent storm dynamics)
* parallel work uses a fixed partitioning and reduction order, so floating-point results don't depend on thread scheduling
* a stage's temporaries (e.g., the mesh's midpoint map and f64 points) live in a scratch arena freed when it returns; only outputs stay (the core keeps ~266 B/vertex today, where ~48 are needed)

## Mesh

* detail field: a deterministic function of (seed, vertex address), independent of the camera's path, that feeds fine terrain (patches now get fine detail from the placeholder's extra noise octaves instead)
* the detail field is applied as midpoint displacement, since raw hashes are white noise: each new vertex starts at the average of its parent edge's endpoints, offset by an amplitude that shrinks with each finer level
* below ~25 m, camera-relative rendering (each patch's vertices relative to its center, offsets from the camera in double precision), since single precision at radius 1 resolves only ~0.4 m
* below ~50 m, the detail field (above) instead of more octaves, so a vertex costs the same at any depth; shading there would come from the lattice's neighbors rather than an exact gradient, which relaxes a vertex shading alike in every patch

## Orbit

* insolation feeds the climate

## Tectonics

* replaces the placeholder elevation
* organically shaped plates, each with a motion vector and crust type (oceanic or continental)
* plates generate gross elevation
* convergent boundaries: mountains (continent–continent), trenches and volcanic arcs (subduction)
* divergent boundaries: ridges and rifts
* transform boundaries: faults

## Regions

* organically shaped regions, with median size set by region scale
* each region carries a terrain field and a climate field

## Terrain

* terrain field: elevation, crust type

## Air

* wind, clouds, storms
* seasonal snow cover

## Climate

* climate field: temperature and precipitation, from latitude, insolation, elevation, and prevailing winds

## Hydrology

* lakes, rivers, deltas, glaciers
* rivers are traced on the coarse level, with flow, since drainage spans whole basins
* fine terrain carves river valleys along refined coarse paths; beds only descend toward the mouth
* seasonal sea ice

## Biome

* derived from terrain and climate

## Next

Tectonics (above) is the next stage: it replaces the placeholder elevation, whose noise has the same gentle slope at every scale, so fine detail barely shows at Earth's relief, and climate, hydrology, and biomes build on it. Smaller work, already scoped:

* parallel synchronous generation (snapshots, benchmarks, video), through `std.Io`, as background generation already is: the benchmark's cold pass would generate in ~0.1 s instead of ~0.5 s
* a sky-view or aerial-perspective table (Hillaire 2020) for the view rays' remaining raymarch, now most of the atmosphere's cost (~60% of the GPU frame); it changes pixels
* the demo's flight path (`LoopingFlight`) into the core, with a test of the loop's seam in place of comparing frames
* view settings (defaults, ranges, and key steps) into the core, only if another front end comes
* the camera's floor from the drawn mesh as well as the true ground: while the finest patches under a fast, low camera are still generating, their coarser parent is drawn, which can lie tens of meters above the camera's 20 m margin
* checks: changing relief while flying (it rebuilds the transmittance table); refresh the README's performance table with a benchmark run; re-record the demo, which predates the finer octaves and the transmittance table

## Practice

* profile release builds outside their app bundle: Instruments launches a bundle by its identifier, which can pick the debug build in `zig-out`
* GPU timings on the M2 vary by over 40% between identical runs (clocks follow the load): compare builds in alternating runs, or by a sustained workload such as `--video`
* run the core's tests with `zig build test`, which uses the coarse level 6; a stale build-options file can carry another level
