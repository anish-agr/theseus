# Roadmap

Milestones are gates: each has acceptance criteria, and features only ship
as solvers over the shared world model (see ARCHITECTURE.md §0).

Standing note (2026-07-28): on-device field testing settled the app's
identity — it ships as a home **inventory** with insurance/move-in-out
evidence as the value, navigation as a supporting tool. The milestones
below track the spatial-OS substrate that identity runs on; the
product's own requirements live in REQUIREMENTS.md.

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
- 90 engine tests green (113 with learning/).

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
- [ ] Optional: my own room video (docs/capture-footage.md) — a
      nice-to-have now, no longer the acceptance gate
- Acceptance: a video of a room becomes a plausible occupancy slice +
  labeled waypoint set, replayed in the viewer. **Met, on real footage.**

## M1 — the app exists (done WITHOUT a Mac — docs/NO-MAC.md)

- [x] **Port engine to Swift package `NavCore` — COMPLETE 2026-07-27.**
      Every module, verified against Python-generated parity fixtures
      (42 Swift tests), culminating in the acceptance milestone: the
      Swift engine REPLAYS ALL THREE GOLDEN SCENARIOS FRAME-FOR-FRAME
      (mini guidance incl. live D* Lite reroutes around a mover,
      mini-explore, mini-walk with safety gates).
- [x] App skeleton (SwiftUI + RealityKit + ARKit session mgmt) —
      apps/ios, XcodeGen spec, **builds green on GitHub's macOS
      runners; unsigned Theseus.ipa artifact per push**
- [x] XR provider v0 written: floor/vertical plane anchors + height-
      banded feature points with persistence → grid (on-device analog
      of the tested Lane A pipeline) — needs on-device validation
- [x] Diagnostic overlay v0 written: live minimap + AR breadcrumbs +
      goal pin + agent entity — needs on-device validation
- [x] On-device trace recorder (same JSONL schema) + share-sheet export
- Acceptance: iPhone XR maps a room live and a virtual agent walks it.
  **Met 2026-07-28** — first on-device field test; seven field tests
  and three releases followed (v0.2 → v1.1).

## M2 — LiDAR, persistence, waypoints, house scale

- [ ] LiDAR provider (`.meshWithClassification`) on 12 Pro+
- [x] ARWorldMap save/load + sidecar — shipped in-app per room
      (LZFSE-compressed map blob + SwiftData world; relocalizes on
      scan resume)
- [x] Named waypoint UX — shipped as the inventory itself: every
      captured thing is a named, locatable anchor
- [ ] Chunked grid + room-graph hierarchical planning (cross-room)
- Acceptance: relocalize into a saved multi-room map and plan across rooms
  instantly. *(Per-room half is live; cross-room needs the room graph.)*

## M3 — Ariadne mode (human guidance)

Field testing demoted guidance from hero to supporting tool — the
default "find" is locate-in-camera (AR beacon + distance-scaled haptic
ticks, shipped), with turn-by-turn one tap away (shipped, voice muted
by default). What remains is the full eyes-up experience:

- [x] Locate haptics (geiger ticks quicken as you close in) + route-
      aware direction that never points through walls
- [x] Voice cues (AVSpeech) baseline over the phone speaker
- [ ] Cue → CoreHaptics corridor patterns (intensity = corridor width)
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
- [x] ONNX export, verified (rl/export.py): 78 KiB per stage, 256/256
      action parity vs SB3, held-out success/SPL reproduced by the
      exported artifact itself
- [ ] ONNX → Core ML behind `SteeringPolicy`; in-app A/B toggle
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
