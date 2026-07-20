# Learning lanes (ML)

This directory hosts everything with real dependencies (PyTorch, ONNX
Runtime, ultralytics, gymnasium…). The engine stays stdlib-only; these
lanes *feed* it (observations in, policies behind existing seams).

Priorities per the 2026-07 decision: **Lane A and B first** (they upgrade
the iPhone XR path and teach deployment), RL + inpainting after (M5/M6).

## Runnable now — zero ML dependencies

The perception/RL *math* is stdlib and tested; only the neural nets need
`requirements.txt`. So the whole chain runs on Windows today against
synthetic ground truth:

```
python learning/demo_depth.py    # depth → occupancy map, opens in the viewer
python learning/demo_detect.py   # noisy detections → named waypoints (fridge/chair/table)
python -m pytest learning -q     # 19 tests: projection, registry, RL env, metrics

# watch the depth lane's output in the same viewer as the planner:
python -m http.server 8123
# → http://localhost:8123/tools/viewer/index.html?trace=depth-trace.jsonl
```

`demo_depth.py` and `demo_detect.py` render a synthetic room, run the
**exact production geometry** (unproject → floor fit → height split →
occupancy ingest; pixel-ray floor projection → merge/promote/decay), and
prove it recovers the room / the objects. Swap the synthetic front-end
for a real model (below) and nothing downstream changes.

### File map

```
depth_projection.py   Lane A/B geometry: intrinsics, (un)project, floor fit,
                      height split, persistence filter, occupancy ingest
scene.py              analytic depth renderer for synthetic rooms (test input)
pipeline.py           frames → viewer trace (reuses engine TraceWriter)
demo_depth.py         Lane A end-to-end demo + golden (fixtures/golden/depth-mini)
demo_detect.py        Lane B end-to-end demo (detections → waypoints)
run_depth.py          Lane A on real footage (onnxruntime) — guarded CLI
run_detect.py         Lane B on real footage (ultralytics) — guarded CLI
rl/env.py             Lane C: Gymnasium NavEnv over the engine sim
rl/rooms.py           procedural room curriculum (empty→static→clutter→movers)
rl/evaluate.py        success-rate + SPL harness (any policy)
rl/train.py           PPO trainer (stable-baselines3) — guarded CLI
tests/                19 tests, no ML deps required
```

Install a lane's real dependencies only when you run its model:
`pip install -r learning/requirements.txt`.

## Lane A — Monocular depth → pseudo-LiDAR (M0.5 offline, M4 on-device)

The XR has no LiDAR; a depth network gives it one. Modern monocular depth
(Depth Anything V2 Small, ~25M params) runs on the A12's ANE at usable
rates.

Offline pipeline (Windows, no phone needed):

1. `pip install onnxruntime opencv-python numpy` (this lane only)
2. Run DA-V2-S on frames of a room video → relative depth map
3. Metric-ish scale: assume camera height + gravity from the video (on
   device this comes free: ARKit pose + intrinsics), RANSAC the floor
   plane, scale so the floor is at 0
4. Un-project: pixel (u,v) + depth d + intrinsics K → camera-space point;
   camera pose → world; keep points in a 0.2–1.8 m height band
5. Filter: confidence mask from depth edges, temporal median over ~5
   frames, cell-level persistence voting (≥k hits)
6. Rasterize hits/free-rays into `OccupancyGrid.observe()` — the exact
   production ingestion path — and write a trace for the viewer

On-device (M4): convert with coremltools (fp16, `compute_units=.ALL`),
target ~5 Hz on ANE; ARKit supplies pose/intrinsics/gravity so steps 3–4
get exact inputs.

## Lane B — Detection waypoints ("go to the fridge" without LiDAR)

1. YOLO11n (ultralytics) on room video → boxes with labels/confidence
2. Project the box's floor contact point: ray through the bottom-center
   pixel, intersect the floor plane (or use Lane A depth) → world point
3. **Waypoint proposal merge policy** (this is engine-worthy logic —
   implement it as a testable module here, port it to Swift later):
   proposals cluster by (label, position ≤0.7 m); confidence accumulates
   on re-sighting, decays on contradicting views; a cluster above
   threshold becomes a named waypoint anchor
4. On-device (M4): try Vision's built-in classifiers first; custom-convert
   YOLO11n via coremltools if furniture classes are needed

## Lane C — Learned steering with RL (M5)

- Env: gymnasium wrapper around `theseus_engine.sim` (deterministic,
  procedurally-generated rooms for train/held-out split)
- Obs: 64×64 egocentric occupancy crop (unknown/free/occupied) + goal
  bearing (sin, cos) + goal distance + previous action
- Actions: discrete — 24 heading bins × {stop, slow, fast}
- Reward: potential-based shaping on D* distance-to-goal (preserves
  optimality!), −collision-proximity, −per-step, −|Δheading| (jerk hurts
  a guided human), +arrival
- Train: PPO (stable-baselines3), curriculum: empty → static clutter →
  1 mover → 3 movers
- Eval vs VFH: success rate, SPL (Anderson et al. 2018), path length
  ratio, jerk
- Deploy: export policy MLP/CNN → Core ML; implement `SteeringPolicy`;
  A/B toggle in the diagnostic HUD

## Lane D — Map inpainting (M6, most research-flavored)

Small UNet: input partial occupancy (+ semantics), predict full occupancy;
training pairs generated by running the sim's sensor over procedurally
generated floorplans. Use: prioritize frontier exploration, prettier
previews. Strictly advisory — predicted cells are never traversable.

## Reading list

- Koenig & Likhachev, *D\* Lite* (AAAI 2002) — the replanner you already
  implemented; read after using it
- Borenstein & Koren, *VFH* (1991) — steering ancestor
- Coulter, *Pure Pursuit* (1992) — the guidance follower
- Thrun et al., *Probabilistic Robotics* ch. 9 — occupancy grids, log-odds
- Anderson et al., *On Evaluation of Embodied Navigation Agents* (2018) — SPL
- Yang et al., *Depth Anything V2* (2024)
- Apple docs: ARKit scene reconstruction, RoomPlan, PHASE, CoreHaptics,
  coremltools
