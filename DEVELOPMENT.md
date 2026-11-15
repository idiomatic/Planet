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
* the camera's floor follows the local surface rather than the planet's highest point

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
