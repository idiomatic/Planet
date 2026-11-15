# Demo video

How [demo.mp4](demo.mp4) and its poster, [demo-poster.jpg](demo-poster.jpg), are made, so they can be re-recorded after the rendering changes. The current video predates the atmosphere.

## Direction

* **Planet:** seed `perihelion`, otherwise Earth's defaults, with relief exaggerated 50× (`--exaggeration 5000`), so the mountains read from altitude.
* **Light:** the sun holds still, about 50° from the zenith over the highest peak, so the relief is lit obliquely throughout and there's no night.
* **Path:** one closed loop around the point beneath the sun, through the highest peak, so the whole flight stays on the sunlit side. Along it:
  * the distance from that point swings ±0.18 radians, three times around the loop;
  * the altitude rises from 0.015 to 0.22 radii above the floor and back, twice, starting low over the summit;
  * the camera looks ahead along the path and down, aiming about 3% of the loop ahead.
* **Loop:** every motion is periodic in the loop's progress, so the last frame leads into the first without a seam.
* **Format:** 2 minutes, 1920×1080, 60 fps, rendered at 2× and scaled down with a Lanczos filter.

The path is `LoopingFlight` in [app/Sources/Video.swift](../app/Sources/Video.swift); changing it changes the video.

## Recording

Build a release, render a near-lossless master (about a minute on an M2, about 700 MB), then encode the copy for the repository in two passes:

```sh
zig build -Drelease
APP="zig-out/Planet.app/Contents/MacOS/Planet"
"$APP" --seed perihelion --exaggeration 5000 --video master.mp4 --bitrate 50

for pass in 1 2; do
  ffmpeg -y -i master.mp4 -c:v libx264 -preset slow -b:v 2900k \
    -maxrate 4500k -bufsize 9000k -pass $pass -profile:v high \
    -pix_fmt yuv420p -g 120 -color_primaries bt709 -color_trc bt709 \
    -colorspace bt709 -movflags +faststart -an \
    $([ $pass = 1 ] && echo "-f mp4 /dev/null" || echo docs/demo.mp4)
done
```

The poster is frame 3,000 (50 seconds in, a fjord coastline), at 1280 pixels wide:

```sh
ffmpeg -y -i master.mp4 -vf "select='eq(n\,3000)',scale=1280:-1" \
  -frames:v 1 -q:v 2 docs/demo-poster.jpg
```

If the path changes, pick a new poster frame from a contact sheet:

```sh
ffmpeg -y -i master.mp4 -vf "select='not(mod(n\,600))',scale=640:-1,tile=4x3" \
  -frames:v 1 sheet.png
```

## Checks

* **Size:** under 50 MB, GitHub's warning threshold (the current copy is 43 MB). Each re-recording adds its size to the repository's history, so re-record only when the look has changed meaningfully.
* **Quality:** SSIM above 0.99 against the master (the current copy is 0.996, PSNR 50 dB):

  ```sh
  ffmpeg -i docs/demo.mp4 -i master.mp4 -lavfi "[0:v][1:v]ssim;[0:v][1:v]psnr" -f null -
  ```

* **Seam:** the change from the last frame to the first should match the change between neighboring frames. Extract the last three and first three frames, in that order, and compare consecutive pairs; the pair across the seam shouldn't stand out:

  ```sh
  ffmpeg -i docs/demo.mp4 -vf "select='gte(n\,7197)'" -fps_mode passthrough a%d.png
  ffmpeg -i docs/demo.mp4 -vf "select='lte(n\,2)'" -fps_mode passthrough b%d.png
  ```

* **Look:** watch it through once, looking for popping, cracks at the horizon, and banding in the sky.

Update the README's caption (size and settings) and the changelog with the new recording.
