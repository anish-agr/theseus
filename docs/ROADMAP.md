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
- 37 tests green.

## M0.5 — ML lanes offline (Windows, next)

Goal: de-risk the two chosen perception ML features with zero Apple
hardware. Details in learning/README.md.

- [ ] Depth: run Depth Anything V2 Small (ONNX) on photos/video of a real
      room; project to a floor-plane point cloud; rasterize into the SAME
      OccupancyGrid; view in the trace viewer
- [ ] Detection: YOLO11n on room video → labeled boxes → waypoint
      proposals with the merge/decay policy implemented + unit-tested
- [ ] Record a phone video walkthrough of Anish's room as the standing
      test asset
- Acceptance: a JPEG/video of a room becomes a plausible occupancy slice +
  labeled waypoint set, replayed in the viewer.

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
- [ ] PHASE spatial-audio beacon at the lookahead point
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

- [ ] Gymnasium env wrapping the engine sim (obs: 64×64 ego occupancy
      crop + goal vector; discrete heading/speed actions)
- [ ] PPO (stable-baselines3), curriculum static → movers; eval success
      rate / SPL / jerk vs VFH
- [ ] Core ML export behind `SteeringPolicy`; in-app A/B toggle
- Acceptance: learned policy ≥ VFH on success rate in held-out rooms, and
  you can flip between them live in the HUD.

## M6 — More solvers + research fun

- [ ] Frontier explore mode (agent auto-maps a room)
- [ ] Coverage/patrol routes; exit flow fields ("evacuation mode")
- [ ] Fit-through queries UI ("will this couch make the turn?")
- [ ] Map inpainting UNet (predict unseen occupancy) feeding explore
- [ ] "What changed since yesterday" chunk diffs
