# Performance

Detailed measurements behind the README's summary. All on an Apple M2 (10-core GPU) with a release build (`zig build -Drelease`) unless noted.

## Benchmark

`--benchmark <frames>` renders offscreen along a path that circles the planet while descending from orbit to the surface, twice (cold, then warm), and reports timings, patch counts, and memory. 300 frames at 2560×1600, mesh off, before the atmosphere:

| | Cold pass | Warm pass |
| --- | ---: | ---: |
| Patches drawn / visited per frame | 574 / 1,056 | 574 / 1,056 |
| Patches generated | 7,752 (0.07 ms each) | 7,336 |
| Cache hit rate | 97.6% | 97.7% |
| Frame without generation (CPU+GPU) | 0.85 ms | 1.08 ms |
| GPU frame | 0.67 ms | 0.84 ms |

Peak memory is 119 MB: the coarse mesh (11 MB), 4,096 cached patches (9.6 KB each, 39 MB), and the render targets. The path's working set (7,752 patches) exceeds the cache's 4,096, so the warm pass regenerates nearly as much as the cold one; within a frame, though, only about 2% of patches are new. Benchmarks generate synchronously, so their mean frame time includes generation; the app generates on background threads and keeps drawing the parent meanwhile.

## Atmosphere

With the atmosphere, the GPU frame rises from about 0.68 to 4.7 ms on the same path (frames from the cache: 1.0 to 3.2–4.5 ms, CPU and GPU), mostly the per-pixel raymarch (12 view steps × 6 sun steps for terrain, 32 × 6 for the sky). A precomputed transmittance table would remove most of the sun steps.

## CPU use

CPU use was cut by drawing only when something changes and by computing the elevation gradient exactly (by the chain rule through the noise and its warp) instead of by finite differences, which sampled the elevation five times per vertex. Patch generation went from 0.275 to 0.072 ms (3.8×), and the benchmark's total CPU time from 5.3 to 2.2 s. In a 4 GB macOS VM, the app's CPU use as `top` reports it:

| | Before | After |
| --- | ---: | ---: |
| Idle, time paused | 17–21% | 0% |
| Idle, time running | 14–22% | 2–4% |
| Flying | ~19% | 11–23% |

Flying still draws at up to 120 fps and generates patches; the rest of its cost is noise, which midpoint displacement (planned) would mostly replace.

## LOD blending

LOD blending costs no measurable GPU time (0.616 vs. 0.612 ms per frame) and 16 bytes per vertex for the parent's values. To measure popping, 80 snapshots approaching the highest peak (30× relief, 640×400) were compared frame to frame; a pop is a frame whose change departs from the average of its neighbors' by more than 0.2 (on a 0–255 scale):

| Blending | Pops | Largest jump | Mean jump |
| --- | ---: | ---: | ---: |
| Off | 12 | 0.35 | 0.092 |
| Ending at 2× the threshold | 9 | 0.60 | 0.086 |
| Ending at 1.5× (default) | 0 | 0.15 | 0.034 |

## Before patches

Before patches, the renderer drew the whole coarse mesh at once, which grew 4× per level: level 9 (2.6 million vertices) took 5.1 ms of GPU per frame and 1.2 GB peak, and level 10 took 15.7 ms and 4.0 GB, while the core kept about 266 bytes per vertex where about 48 are needed (its arena keeps generation leftovers). Patches reach level 12 detail near the camera for far less.
