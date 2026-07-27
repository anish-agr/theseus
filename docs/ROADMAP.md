# Roadmap

Milestones are gates: each has acceptance criteria, and features only ship
as solvers over the shared world model (see ARCHITECTURE.md §0).

## M0 — Engine on Windows ✅ (2026-07)

- [x] Occupancy grid: bounded log-odds, semantics, capped clearance field
- [x] A* + smoothing, property-tested optimal vs Dijkstra
- [x] D* Lite, property-tested ≡ A* under random edits + start moves
- [x] VFH steering with hysteresis; guidance cues with tested turn signs
- [x] Navigation FSM incl. tracking-loss resume
- [x] Deterministic simulator (limited-FOV sensor, movers, collisions)
- [x] Studio demo: map → guide to fridge past a pacing person, 0 collisions
- [x] Golden trace fixtures + HTML replay viewer
- [x] Walk mode: goal-free VFH roam + sensor-freshness & swept-body
      safety gates (added after M0; golden, 0 collisions with a mover)
- 89 engine tests green (113 with learning/).

## M0.5 — ML lanes offline (Windows) — largely ✅

Goal: de-risk the ML features with zero Apple hardware. Details in
learning/README.md. The projection/registry/RL *math* is done and tested
against synthetic ground truth; what remains needs a real model + footage.

- [x] Depth projection pipeline: unproject → gravity floor-fit → height
      split → temporal persistence → occupancy ingest, all stdlib + tested;
      `demo_depth.py` recovers a room and writes a viewer trace (golden)
- [x] Detection→waypoint chain: pixel-ray floor projection + merge/promote/
      decay registry; `demo_detect.py` recovers fridge/chair/table from
      noisy synthetic detections, rejects ghosts (golden-style test)
- [x] RL groundwork (pulled forward from M5): Gymnasium `NavEnv` over the
      engine sim, procedural curriculum, SPL/success eval harness, scripted
      baseline — all tested; PPO trainer wired (needs torch)
- [x] Guarded real-model runners: `run_depth.py` (onnxruntime),
      `run_detect.py` (ultralytics)
- [x] Run DA-V2-S / YOLO11n on real footage — **done 2026-07-26 on
      public footage**: Pexels clips (YOLO → fridge/oven/table/chairs
      waypoints) + TUM fr1_desk (real handheld video with mocap
      ground-truth poses; learning/tum_prep.py converts, run_depth
      --sparse aligns relative depth to meters the way ARKit feature
      points will on-device). Result: coherent metric floor plan;
      130/133 camera-track cells FREE, 0 OCC. Known limit (measured):
      floor-ray waypoint placement overshoots for elevated objects
      (desk monitors) — depth-fused placement is the M4 fix.
- [ ] Optional: Anish's own room video (docs/capture-footage.md) — a
      nice-to-have now, no longer the acceptance gate
- Acceptance: a video of a room becomes a plausible occupancy slice +
  labeled waypoint set, replayed in the viewer. **Met, on real footage.**

## M1 — Mac + Xcode: the app exists

- [ ] Xcode project skeleton (SwiftUI + RealityKit + ARKit session mgmt)
- [ ] Port engine to Swift package `NavCore`, module-by-module, tests
      first; golden scenario hashes reproduced
- [ ] XR provider: plane detection + filtered feature points → grid
- [ ] Diagnostic overlay v0: grid decal + path + agent on camera feed
- [ ] On-device trace recorder (same JSONL schema)
- Acceptance: iPhone XR maps a room live and a virtual agent walks it.

## M2 — LiDAR, persistence, waypoints, house scale

- [ ] LiDAR provider (`.meshWithClassification`) on 12 Pro+
- [ ] ARWorldMap save/load + sidecar (grid chunks, room graph, waypoints)
- [ ] Named waypoint UX ("Kitchen Fridge") on anchors
- [ ] Chunked grid + room-graph hierarchical planning
- Acceptance: relocalize into a saved multi-room map and plan across rooms
  instantly.

## M3 — Ariadne mode (human guidance, the hero)

- [ ] Cue → CoreHaptics corridor patterns (intensity = corridor width)
- [ ] Phone-speaker audio beacon + voice as the BASELINE (no AirPods
      available — head-tracked spatial audio is a future nicety, not a
      dependency)
- [ ] Voice cues (AVSpeech) + big-type HUD
- [ ] On-body test protocol (blindfold tests come much later, with a
      spotter, after weeks of sighted validation)
- Acceptance: a sighted tester crosses a cluttered room eyes-up on haptics
  + audio alone.

## M4 — On-device ML perception

- [ ] Depth Anything V2 S → Core ML (ANE), 5 Hz DepthMLProvider on XR
- [ ] Detection → waypoint proposals on-device ("go to the fridge" without
      LiDAR)
- Acceptance: XR mapping quality visibly approaches the LiDAR path in the
  same room; fridge navigable by name on XR.

## M5 — Learned steering (RL)

- [x] Gymnasium env wrapping the engine sim (15×15 ego occupancy crop +
      goal vector; 10 discrete heading/speed actions) — tested
- [x] PPO (stable-baselines3) full curriculum, warm-started stage to
      stage — **trained 2026-07-24, held-out results (success / SPL,
      learned vs baseline): static 0.90/0.85 vs 0.60/0.60 · movers1
      0.90/0.86 vs 0.37/0.37 · movers3 0.87/0.73 vs 0.30/0.30** — the
      gap WIDENS as movers are added; weights in learning/rl/runs/
- [ ] Core ML export behind `SteeringPolicy`; in-app A/B toggle
- Acceptance: learned policy ≥ VFH on success rate in held-out rooms, and
  you can flip between them live in the HUD.

## M6 — More solvers + research fun (engine side pulled forward ✅)

- [x] Frontier explore mode (agent auto-maps a room — golden, 100% floor)
- [x] Coverage/patrol routes; exit flow fields ("evacuation mode")
- [x] Fit-through queries ("will this couch make the turn?") — UI at M1+
- [x] Map inpainting UNet — **trained 2026-07, beats nearest-known
      baseline on held-out rooms (acc 0.844/0.770, IoU_occ 0.587/0.388)**;
      on-device advisory integration later
- [x] "What changed since yesterday" diffs (serialize.py kernel; chunked
      per-room hashing lands with M2 persistence)
- [ ] Multi-floor (stairs as portal edges); multi-device shared maps
