# Feature ledger — everything we set out to build, and where it stands

Status key: ✅ done & tested · 🧪 done offline, needs real input ·
🍎 blocked on Mac/Xcode (M1+) · 📷 blocked on LiDAR loaner (M2) ·
⬜ not started. "Engine" = the Python reference that ports to Swift.

## The original vision (first design doc)

| feature | status | where |
|---|---|---|
| A*/D* Lite pathfinding, verified off-device | ✅ property-tested equal | engine/astar.py, dstar_lite.py |
| Real-time dynamic rerouting around moving obstacles | ✅ golden demo, 0 collisions | demo: studio guidance, 7 live reroutes |
| Accessibility guidance ("Ariadne mode") — cues a human can follow | ✅ engine cues (turn sign tested) · 🍎 haptics/audio/voice (M3) | guidance.py; docs/ARCHITECTURE.md §5 |
| Continuous walk mode ("longest unobstructed vector") | ✅ VFH + hysteresis + safety gates, golden | steering.py, controller.run_walk |
| Semantic object detection → custom named waypoints | ✅ engine registry + 🧪 offline chain proven synthetically · 🍎 on-device (M4) | waypoints.py, learning/demo_detect.py |
| Spatial persistence — save/load, relocalize | ✅ grid sidecar kernel (save/load/diff) · 🍎 ARWorldMap (M2) | serialize.py |
| House-scale (not just one room) | ⬜ chunked grid + room graph (M2, designed) | ARCHITECTURE.md §2 |
| Diagnostic visual overlay | ✅ desktop trace viewer (all demos) · 🍎 RealityKit overlay (M1) | tools/viewer |
| Async perception/logic split for 60 fps | ✅ designed (actor pipeline, rate budgets) · 🍎 implement at M1 | ARCHITECTURE.md §8 |
| Mesh/sensor → navigation graph conversion | ✅ sim + depth ingestion paths · 🍎 ARKit mesh voxelizer (M1/M2) | grid.observe, depth_projection.ingest |
| iPhone XR (no LiDAR) fallback as primary path | 🧪 depth pseudo-LiDAR pipeline proven synthetically | learning/demo_depth.py |

## Extra solvers (the "spatial OS" additions)

| feature | status | where |
|---|---|---|
| Frontier auto-explore (agent maps a room itself) | ✅ golden, 100% floor discovered | frontier.py, run_explore |
| Evacuation flow fields ("way out from anywhere") | ✅ property-tested vs A* | flowfield.py |
| Coverage/patrol sweeps | ✅ 98% floor coverage in studio | coverage.py |
| "Will the couch fit through?" (fit-through) | ✅ finds the real 0.60 m pinch | queries.py |
| "Take me to the nearest X" (semantic query) | ✅ with body-realistic approach points | queries.py |
| "What changed since yesterday" (map diff) | ✅ kernel (labeled diff reports) | serialize.py |
| One-command showcase of all of the above | ✅ | engine/scripts/showcase.py |

## ML lanes

| lane | status | evidence |
|---|---|---|
| A — monocular depth → occupancy | 🧪 full pipeline + golden; runner ready | floor-fit, height-split, persistence, ingest all tested |
| B — detection → named waypoints | 🧪 recovers objects to 1–3 cm, rejects ghosts; runner ready | demo_detect tests |
| C — RL steering | ✅ **PPO trained (static stage), beats baseline on held-out rooms: success 0.90 vs 0.60, SPL 0.85 vs 0.60, half the steps** · movers stages next (warm-started curriculum) | learning/rl/ |
| D — map inpainting | ✅ **UNet trained on this machine, beats baseline on held-out rooms: acc 0.844 vs 0.770, IoU_occ 0.587 vs 0.388** | learning/inpaint/ |

## What unblocks the remaining items

1. **Footage** (you, ~15 min): docs/capture-footage.md. Unlocks Lanes
   A/B on reality → the real-footage acceptance for M0.5. Everything
   else is staged: deps installed, DA-V2-Small ONNX + yolo11n.pt
   downloaded (learning/models/, gitignored), both runners verified
   end-to-end on a synthetic video (2026-07-24).
2. **Mac** (weeks away): M1 Swift port — mechanical, against goldens,
   guide written (docs/PORT.md) — then ARKit shell + overlay.
3. **iPhone 12 Pro+ loaner** (M2): LiDAR provider, RoomPlan rooms/doors.
4. Nothing else. No other hardware, accounts, or services needed until
   App-Store time.
