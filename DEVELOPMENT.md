# Development

## Parameters

Entered on a sheet before generation; defaults are Earth's.

* seed (user-provided)
* planet radius scale (% of Earth)
* radial exaggeration (%, display only)
* region scale (float ≥ 1, relative to Earth): larger gives fewer, larger regions, up to comically large
* sea level (% of the surface elevation range, from lowest to highest; default 55%)
* axial tilt (degrees)
* day length (relative to Earth)
* year length (relative to Earth)

## Viewer

* simplified flight controls
* time speed (%)
* no save or export; the seed and parameters reproduce a planet

## Pipeline

* stages run in order: orbit → tectonics → terrain → air → climate → hydrology → biome
* everything is generated once and static, except human-scale phenomena (e.g., day/night, seasons, weather), which change while time runs

## Mesh

* icosphere, 12 subdivision levels (~1.6 km edges at Earth radius)
* the core stores per-vertex fields globally only at a coarse level (compile-time parameter, default 6, ~105 km edges)
* finer levels are generated on demand around the camera as it travels, and evicted behind it
* vertex address: subdivision path (base face, then child index per level) plus corner; a vertex shared by several triangles uses its lowest address, so shared vertices agree
* detail field: a deterministic function of (seed, vertex address), independent of the camera's path, that feeds fine terrain
* the detail field is applied as midpoint displacement, since raw hashes are white noise: each new vertex starts at the average of its parent edge's endpoints, offset by an amplitude that shrinks with each finer level
* rendering uses adaptive level of detail

## Orbit

* rotation (day/night), axial tilt, and orbit (seasons)
* insolation feeds the climate

## Tectonics

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
