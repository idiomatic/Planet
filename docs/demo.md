# Demo video

How the README's demo video is made, so it can be re-recorded after the rendering changes. GitHub plays a video inline only from an uploaded attachment, so the video lives in [issue #1](https://github.com/idiomatic/Planet/issues/1), not in the repository, which keeps it out of the history.

## Direction

* **Planet:** seed `Mihira`, otherwise Earth's defaults, with relief exaggerated 50× (`--exaggeration 5000`), so the mountains read from altitude.
* **Light:** the sun holds still, about 50° from the zenith over the highest peak, so the relief is lit obliquely, except at the sunset.
* **Path:** one closed loop around the point beneath the sun, through the highest peak, on the sunlit side. Along it:
  * the distance from that point swings ±0.12 radians, three times around the loop;
  * halfway round, low over the ground, it swings out past the terminator until the sun stands 3° above the visible horizon, and the camera turns toward it: a sunset, with the ground below in dusk (with relief exaggerated 50×, the camera's floor, the highest peak, is too high to see the sun near the horizon with the ground below still lit);
  * the altitude rises from 0.015 to 0.22 radii above the floor and back, twice, starting low over the summit;
  * the camera looks ahead along the path and down, aiming about 3% of the loop ahead.
* **Loop:** every motion is periodic in the loop's progress, so the last frame leads into the first without a seam.
* **Format:** 2 minutes, 60 fps; the master is 1920×1080, rendered at 2× and scaled down with a Lanczos filter; the uploaded copy is 1280×720.

The path is `LoopingFlight` in [app/Sources/Video.swift](../app/Sources/Video.swift); changing it changes the video.

## Recording

Build a release, render a near-lossless master (about 7 minutes on an M2, mostly raymarching the atmosphere at the 3840×2160 render size; about 740 MB), then encode the copy for uploading in two passes, at 720p and about 0.62 Mbps to fit GitHub's 10 MB limit for uploaded videos (on a free plan):

```sh
zig build -Drelease
APP="zig-out/Planet.app/Contents/MacOS/Planet"
"$APP" --seed Mihira --exaggeration 5000 --video master.mp4 --bitrate 50

for pass in 1 2; do
  ffmpeg -y -i master.mp4 -vf "scale=1280:720:flags=lanczos" \
    -c:v libx264 -preset veryslow -b:v 620k -maxrate 1200k \
    -bufsize 2400k -pass $pass -profile:v high -pix_fmt yuv420p \
    -g 120 -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -movflags +faststart -an \
    $([ $pass = 1 ] && echo "-f mp4 /dev/null" || echo demo.mp4)
done
```

Upload it as a comment on [issue #1](https://github.com/idiomatic/Planet/issues/1), read back its `user-attachments` URL, and check that it's live (302 or 403; a dead one answers 404):

```sh
gh issue comment 1 --repo idiomatic/Planet --body "Re-recorded: …" \
  --attach demo.mp4
gh issue view 1 --repo idiomatic/Planet --comments
curl -sS -o /dev/null -w '%{http_code}\n' -I <url>
```

Put the URL on its own line in the README, replacing the old one; GitHub renders it as a player, showing the first frame before it plays. Attachments are immutable, so each re-recording gets a new URL.

To review the look, make a contact sheet:

```sh
ffmpeg -y -i master.mp4 -vf "select='not(mod(n\,600))',scale=640:-1,tile=4x3" \
  -frames:v 1 sheet.png
```

## Checks

* **Size:** under 10 MB, GitHub's limit for uploaded videos on a free plan (the current copy is 9.5 MB).
* **Quality:** SSIM about 0.99 against the master scaled to 720p (the current copy is 0.990):

  ```sh
  ffmpeg -i demo.mp4 -i master.mp4 \
    -lavfi "[1:v]scale=1280:720:flags=lanczos[r];[0:v][r]ssim" -f null -
  ```

* **Seam:** the change from the last frame to the first should match the change between neighboring frames. Extract the last three and first three frames, in that order, and compare consecutive pairs; the pair across the seam shouldn't stand out:

  ```sh
  ffmpeg -i demo.mp4 -vf "select='gte(n\,7197)'" -fps_mode passthrough a%d.png
  ffmpeg -i demo.mp4 -vf "select='lte(n\,2)'" -fps_mode passthrough b%d.png
  ```

* **Look:** watch it through once, looking for popping, cracks at the horizon, and banding in the sky.

Update the README's URL and caption and the changelog with the new recording.
