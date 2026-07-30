# Feature ledger — everything we set out to build, and where it stands

Status key: ✅ done & tested · 🧪 done offline, needs real input ·
📷 blocked on LiDAR loaner (M2) · ⬜ not started. "Engine" = the
Python reference; "NavCore" = its verified Swift port; "app" = the
shipped iOS app (v1.1). Nothing below waited for a Mac — the app is
compiled by CI on cloud macOS runners (docs/NO-MAC.md).

## The original vision (first design doc)

| feature | status | where |
|---|---|---|
| A*/D* Lite pathfinding, verified off-device | ✅ property-tested equal, ported | engine/astar.py, dstar_lite.py; NavCore |
| Real-time dynamic rerouting around moving obstacles | ✅ golden demo, 0 collisions; replayed frame-for-frame by NavCore | demo: studio guidance, 7 live reroutes |
| Accessibility guidance ("Ariadne mode") — cues a human can follow | ✅ engine cues (turn sign tested) + on-device haptics/voice (guidance view + locate geiger ticks; voice muted by default) | guidance.py; app GuidanceView, LocateBar |
| Continuous walk mode ("longest unobstructed vector") | ✅ VFH + hysteresis + safety gates, golden | steering.py, controller.run_walk |
| Semantic object detection → custom named waypoints | ✅ in-app: captures become named, locatable things · 🧪 YOLO-class detection on-device at M4 | app ObjectCapture; learning/demo_detect.py |
| Spatial persistence — save/load, relocalize | ✅ app: LZFSE ARWorldMap + SwiftData sidecar, relocalize on scan resume | Store.swift; serialize.py |
| House-scale (not just one room) | ⬜ chunked grid + room graph (M2, designed) | ARCHITECTURE.md §2 |
| Diagnostic visual overlay | ✅ desktop trace viewer + in-app AR markers & rasterized minimap | tools/viewer; app ARViewContainer, MinimapView |
| Async perception/logic split for 60 fps | ✅ shipped the hard-won version: 30 Hz frame budget, publish-on-change pose, session pause off-tab | app ARSessionManager, NavEngine |
| Mesh/sensor → navigation graph conversion | ✅ planes + feature points → grid (XR path) · 📷 LiDAR mesh voxelizer | app NavEngine ingest; grid.observe |
| iPhone XR (no LiDAR) fallback as primary path | ✅ it IS the shipped scan path; depth-ML upgrade at M4 | app; learning/demo_depth.py |

## Extra solvers (the "spatial OS" additions)

| feature | status | where |
|---|---|---|
| Frontier auto-explore (agent maps a room itself) | ✅ golden, 100% floor discovered | frontier.py, run_explore |
| Evacuation flow fields ("way out from anywhere") | ✅ property-tested vs A* | flowfield.py |
| Coverage/patrol sweeps | ✅ 98% floor coverage in studio | coverage.py |
| "Will the couch fit through?" (fit-through) | ✅ engine + app screen | queries.py; app FitThroughView |
| "Take me to the nearest X" (semantic query) | ✅ with body-realistic approach points | queries.py |
| "What changed since yesterday" (map diff) | ✅ engine kernel + app diff screen with map view | serialize.py; app ChangesView |
| One-command showcase of all of the above | ✅ | engine/scripts/showcase.py |

## The app (v0.2 → v1.1 — the field-test era)

The product found its identity on-device: an inventory with a spatial
memory, where insurance/move-in-out evidence is the value and
navigation assists. docs/REQUIREMENTS.md tracks the letter of it.

| feature | status |
|---|---|
| Scan → lock-on capture → batch ✨ AI identify (names, values, confidence) | ✅ |
| AI providers: Gemini free tier / Claude / any OpenAI-compatible; keys in Keychain; self-healing retry loop | ✅ |
| Storage spots: multi-photo AI itemizing with per-item crops, printable QR labels, deep links | ✅ |
| Insurance: serial OCR, receipts (on-device OCR), warranties, claim PDF, insure-my-home wizard | ✅ |
| Condition records: sealed SHA-256 move-in/out evidence + compare PDF | ✅ |
| Exports: room report PDF, floor plan PNG, inventory JSON, move manifest, household snapshot, full backup .zip | ✅ |
| Locate-in-camera (route-aware arrow, geiger haptics) + turn-by-turn one tap away | ✅ |
| Voice ("mark this / what is this / find my X", on-device speech) | ✅ |
| Spotlight indexing + App Intents | ✅ |
| Lens mode (visual lookalike match) & memory lane | ✅ |
| Camera point-and-measure, backup import, height-aware fit | ⬜ deferred by choice |

## ML lanes

| lane | status | evidence |
|---|---|---|
| A — monocular depth → occupancy | ✅ **real footage (TUM fr1_desk): metric floor plan from handheld video; 130/133 camera-track cells FREE, 0 falsely blocked** | learning/RESULTS.md |
| B — detection → named waypoints | ✅ **real footage: fridge/ovens/table/chairs promoted, 0 ghosts; elevated-object overshoot measured → M4 depth-fusion fix** | learning/RESULTS.md |
| C — RL steering | ✅ **PPO curriculum trained; held-out success 0.90/0.90/0.87 vs baseline 0.60/0.37/0.30; exported to verified 78 KiB ONNX** · Core ML at M5 | learning/RESULTS.md |
| D — map inpainting | ✅ **UNet beats baseline on held-out rooms: acc 0.844 vs 0.770, IoU_occ 0.587 vs 0.388** | learning/RESULTS.md |

## What unblocks the remaining items

1. **iPhone 12 Pro+ loaner** (M2): LiDAR mesh provider, RoomPlan
   rooms/doors, house-scale room graph.
2. **A Mac, eventually** — not for building (CI does that) but for the
   tight ARKit iteration loop of M4 (Core ML depth on-device) and the
   coremltools conversion. A used M1 Mini covers it.
3. **$99/yr Apple Developer account** — only if this ever goes to
   TestFlight/App Store; sideloading needs nothing.
