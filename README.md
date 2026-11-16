# Planet

Planet generates an Earth-like planet from a seed, any text you like, and lets you fly around it, from orbit down to mountain valleys, with a day and night cycle, seasons, and a scattering atmosphere. The same seed always makes the same planet.

https://github.com/user-attachments/assets/8356c427-d77b-459e-b8af-666fced457e9

A two-minute looping flight over the planet "Mihira," with relief exaggerated 50×, through the atmosphere and a sunset.

![The planet "Mihira" from orbit](docs/mihira.png)

The terrain is a placeholder (warped fractal noise) until plate tectonics lands; [DEVELOPMENT.md](DEVELOPMENT.md) lists what's planned, and [AGENTS.md](AGENTS.md) is the full specification.

## Getting Planet

Planet runs on macOS 15 or later, on Apple silicon.

### Downloading

Download `Planet-…-macos-arm64.zip` from the [latest release](https://github.com/idiomatic/Planet/releases/latest) and unzip it. Planet isn't notarized (it's signed ad hoc), so macOS quarantines a downloaded copy and refuses to open it, saying it can't be verified or is damaged. If you trust where it came from, either:

* remove the quarantine, then open it as usual:

  ```sh
  xattr -dr com.apple.quarantine Planet.app
  ```

* or try to open it once, then choose Open Anyway in System Settings › Privacy & Security, and confirm.

### Building from source

With [Zig](https://ziglang.org) 0.17 or later and Xcode's command-line tools:

```sh
zig build run   # build and launch
zig build test  # core tests
```

The app is installed at `zig-out/Planet.app`. A copy built on your own Mac isn't quarantined.

## Using Planet

Type a seed in the sidebar (any text, such as `Mihira`) and choose Generate. The sidebar's Planet section holds what shapes the planet (the seed and region scale), applied by Generate. Its View section changes the view live while you fly: relief, sea level, air density, axial tilt, day and year length, detail, patch cache size, exposure, and field of view. A larger patch cache (40 MB by default) regenerates less terrain when you return to places you've flown over, at the cost of memory. Ticks under the sliders mark Earth's values; click one to snap back. The globe button resets everything to Earth's values. ⌃⌘I or the toolbar button shows and hides the sidebar.

| Control | Action |
| --- | --- |
| Drag | Look around |
| Scroll | Zoom toward where you're looking |
| W / S, A / D, R / F | Fly forward and back, left and right, up and down |
| Q / E | Roll |
| Shift | Fly faster |
| Space | Pause and resume time |
| `,` / `.` | Slow down and speed up time (10× per step) |
| H | Turn the air off and on |
| `[` / `]` | Thin and thicken the air |
| `-` / `=` | Flatten and exaggerate the relief |
| M | Show the triangle mesh |
| B | Turn LOD blending off and on |

Flight speed scales with altitude, so the same keys work from orbit down to the ground, and you can't fly into the terrain.

## Command line

Command-line switches set the parameters and the starting camera, and open straight to a planet, with the sidebar closed unless `--sidebar open`. `--help` lists them:

```sh
"zig-out/Planet.app/Contents/MacOS/Planet" --help
```

For example, to start beside the highest peak with 30× relief and time paused:

```sh
zig build run -- --seed Mihira --exaggeration 3000 --distance 1.12 \
  --look-at peak --time-speed 0
```

Every switch takes a value: AppKit reads arguments in `-key value` pairs and opens any leftover argument as a file, which suppresses the window.

To render a still without opening a window, as for the image above:

```sh
"zig-out/Planet.app/Contents/MacOS/Planet" \
  --snapshot docs/mihira.png --seed Mihira --direction 1,0.3,1
```

To render a looping flight video (2 minutes at 1080p60 takes about 6 minutes on an M2, mostly the atmosphere):

```sh
"zig-out/Planet.app/Contents/MacOS/Planet" \
  --seed Mihira --exaggeration 5000 --video demo.mp4
```

The demo above was made this way, encoded under GitHub's 10 MB limit for uploaded videos, and is hosted in [an issue](https://github.com/idiomatic/Planet/issues/1); [docs/demo.md](docs/demo.md) has the directions for re-recording it.

## Performance

Planet aims to fly smoothly at full detail on a base M1 and to use no power when nothing moves. The strategies:

* **Detail only where it's seen.** A full-resolution planet (168 million vertices) wouldn't fit in an 8 GB Mac's memory, so only a coarse mesh (~105 km triangles) is stored. Finer patches, down to ~1.6 km triangles, are generated around the camera, refined by their size on screen, and culled outside the view or behind the horizon.
* **Generation off the main thread.** Missing patches are generated on background threads, largest on screen first, while their parent stays drawn; a cache keeps them between frames (40 MB, about 4,100 patches, by default; adjustable while flying).
* **Cheap generation.** The terrain's slope is computed exactly alongside its height, instead of by sampling the height five times, so a patch takes 0.07 ms (3.8× faster).
* **Drawing only on change.** Frames are drawn only while something moves (up to 120 fps while flying, 30 fps while time runs); idle with time paused uses no CPU.
* **Smooth transitions for free.** LOD blending eases each new patch in from its parent's shape, removing popping at no measurable GPU cost.

On an Apple M2 at 2560×1600, flying from orbit to the surface:

| | Result |
| --- | ---: |
| GPU frame, terrain alone | 0.7 ms |
| GPU frame, with the atmosphere | 4.7 ms |
| Patches drawn per frame | 574 |
| Patch cache hit rate | 98% |
| Peak memory | 119 MB |
| CPU idle, time paused / running | 0% / 2–4% |

The atmosphere's raymarch is now most of the frame; a precomputed transmittance table (planned) would remove most of its cost. [docs/performance.md](docs/performance.md) has the full measurements.

## Design notes

* **Reproducible planets.** Generation is deterministic, so a seed and its parameters fully describe a planet; there's nothing to save or export.
* **Region scale.** Values above 1 exaggerate regions, simplifying the planet as seen from orbit; below 1 would be absurd in a different way, so it isn't allowed.
* **Patches.** A patch's vertices come from the same midpoint normalizations as the coarse mesh and an exact gradient, so neighbors agree exactly where they share vertices; skirts cover the T-junctions where a fine patch meets a coarser one.
* **Vertex addresses.** A vertex on a shared edge or corner is reachable by several subdivision paths; picking the lowest gives it one detail value, so neighboring triangles don't crack apart.
* **Detail field.** Hashing (seed, address) alone yields uncorrelated white noise; midpoint displacement with shrinking amplitude turns it into natural-looking terrain.
* **Time.** Only human-scale phenomena change while time runs; geology is generated once.

## Prior art

* [PISES: The Icospherical World Model](https://www.youtube.com/watch?v=LqNOHvYneYk) by Keegan Tawa (video)

## How it was made

Planet was written with [Claude](https://claude.com).

## License

BSD 3-Clause; see [LICENSE](LICENSE).
