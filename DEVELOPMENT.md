# Development

## Pipeline

* stages run in order: orbit → tectonics → terrain → air → climate → hydrology → biome
* everything is generated once and static, except human-scale phenomena (e.g., day/night, seasons, weather), which change while time runs

## Mesh

* icosphere, 12 subdivision levels (~1.6 km edges at Earth radius)
* finer levels than the coarse one are generated on demand around the camera as it travels, and evicted behind it
* detail field: a deterministic function of (seed, vertex address), independent of the camera's path, that feeds fine terrain
* the detail field is applied as midpoint displacement, since raw hashes are white noise: each new vertex starts at the average of its parent edge's endpoints, offset by an amplitude that shrinks with each finer level
* rendering uses adaptive level of detail

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
