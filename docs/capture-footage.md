# Capturing test footage (iPhone XR)

The depth (Lane A) and detection (Lane B) pipelines are fully built and
tested against synthetic scenes. Real footage of YOUR room is the next
acceptance gate: it exposes everything synthetic scenes can't — sensor
noise, motion blur, lighting, weird furniture.

**A messy room is a feature, not a problem.** A clean room is the easy
case; clutter is what stresses depth edges, spawns detector false
positives, and creates the tight corridors the planner exists for. The
whole app is being built for real cluttered homes. Also: footage never
leaves your machine — the `footage/` directory is gitignored, and only
tiny derived artifacts (traces, waypoint JSONs) get committed.

## Phone settings (do once, before recording)

1. Settings → Camera → Formats → **Most Compatible** (H.264 — avoids
   HEVC codec pain on Windows).
2. Record **1080p at 30 fps** (Settings → Camera → Record Video).
3. In the Camera app, **landscape**, rear wide lens (1x, not selfie).
4. **Lock exposure/focus**: tap-and-hold the scene until `AE/AF LOCK`
   shows. Exposure flicker makes depth models jump frame-to-frame.
5. Wipe the lens.

## How to move

- Hold the phone with two hands at a **constant height you have
  measured** (e.g. 1.40 m — write it down, it becomes `--height`).
- **Tilt down ~30°** so the floor 1.5–3 m ahead stays in frame — the
  floor-fit step depends on seeing floor. (`--pitch 0.5` ≈ 29°.)
- Walk **slow and smooth** (~0.3 m/s, half normal pace). Translation
  with overlap is what depth+detection want; avoid spin-in-place pans
  and fast whips (motion blur is poison).
- For each object you care about (fridge, chair, table, bed…):
  **approach to 1–3 m and hold on it 2–3 seconds**. The waypoint
  registry promotes a target only after repeated sightings.
- Finish by walking back toward your start point.

## Avoid / note down

- Mirrors, glass, TVs — they lie to depth models. Fine if present, just
  note where they are so odd map artifacts have an explanation.
- Windows blowing out exposure; very dark rooms.
- People walking through — unless you WANT a movers clip (great!), then
  label it as such.

## The clips

| # | clip | length | purpose |
|---|------|--------|---------|
| 1 | `room-sweep-01.mp4` — slow lap of the room, floor visible | ~60–90 s | Lane A occupancy mapping |
| 2 | `obj-fridge-01.mp4` etc. — approach + dwell per object | ~10 s each | Lane B waypoints |
| 3 | `fov-calib-01.mp4` — see below | ~5 s | intrinsics calibration |
| 4 | (optional) `movers-01.mp4` — someone crosses your path | ~30 s | dynamic-obstacle stress |

**FOV calibration (2 minutes, do it once):** put two pieces of tape on a
wall. Stand at a measured distance D (e.g. 2.00 m), frame the wall, and
slide the tape marks until they sit exactly at the LEFT and RIGHT edges
of the video frame. Measure the tape-to-tape distance X. Then
`hfov = 2·atan((X/2)/D)` — feed that into `--hfov` (the default is a
guessed 68°).

## Getting it onto the PC and "into the repo"

Videos do NOT get committed to git (100 MB binaries don't belong in a
repo). The flow is:

1. Transfer: USB cable → Windows Photos import, or iCloud for Windows,
   or upload to Drive/OneDrive from the phone and download.
2. Drop the files into `footage/` in the repo — it's **gitignored**, so
   they stay local.
3. Fill in one line per clip in `footage/README.md` (tracked): filename,
   camera height, what's in it, mirrors/glass notes. That manifest is
   the repo's record of the footage.
4. What DOES get committed: the small derived artifacts —
   `run_depth.py` traces, `run_detect.py` waypoint JSONs — plus any
   goldens we promote from them.

Then, with one dependency install (`pip install -r
learning/requirements.txt`) and a depth model download, the runners go:

```
python learning/run_depth.py  --video footage/room-sweep-01.mp4 --model <depth.onnx> --height 1.40 --pitch 0.5
python learning/run_detect.py --video footage/room-sweep-01.mp4 --height 1.40 --pitch 0.5
```
