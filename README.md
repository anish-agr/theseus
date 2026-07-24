# Theseus

**A spatial navigation OS for the iPhone**: scan a real room into a live 3D
world model, then run solvers over it — guide a person around the furniture,
send a virtual agent exploring, answer "will this couch fit through the
hallway", find the fridge by name.

> **Why "Theseus"?** In 1950 Claude Shannon built *Theseus*, a mechanical
> mouse that learned to solve a maze — arguably the first machine-learning
> demo in history. And in the myth, Theseus survives the labyrinth by
> following Ariadne's thread. This project is both: classical pathfinding
> first, learned behavior on top. The human-guidance mode is nicknamed
> **Ariadne mode** — the app holds the thread, you follow it.

## Status — M0 engine ✅ · M0.6 solvers ✅ · M0.5 ML lanes 🧪 (113 tests)

Everything below runs on Windows with zero dependencies (the ML lanes'
neural nets are optional extras — and the **inpainting UNet is already
trained**: it beats the classical baseline on held-out rooms, acc 0.844
vs 0.770). Full ledger: [docs/CHECKLIST.md](docs/CHECKLIST.md).

```
python -m pytest engine learning -q     # 113 tests
python engine/scripts/generate.py       # all demo traces + goldens
python engine/scripts/showcase.py       # fit-through, exits, coverage, semantics
python learning/demo_depth.py           # depth -> occupancy, viewable
python learning/demo_detect.py          # detections -> named waypoints
python -m http.server 8123              # viewer: /tools/viewer/index.html
#   ?trace=demo-trace.jsonl (guidance) ?trace=explore-trace.jsonl
#   ?trace=walk-trace.jsonl            ?trace=depth-trace.jsonl
```

### The original M0 core

The navigation core is a **pure-Python, stdlib-only** reference
implementation, developed and property-tested on Windows before any Apple
hardware is involved. It already does the whole loop headlessly:

- incremental **occupancy world model** (bounded log-odds, semantics,
  clearance field) built from simulated limited-FOV sensing
- **A\*** (optimality property-tested against Dijkstra) and **D\* Lite**
  (property-tested equal to fresh A\* across random world edits and agent
  moves — replans cost *milliseconds*, not a rebuild)
- **VFH steering** with hysteresis, **pure-pursuit guidance cues**
  (straight / turn left 43° / off-route / arrive), an explicit **state
  machine**, and a deterministic simulator with moving obstacles
- golden-trace fixtures that freeze behavior byte-for-byte — the future
  Swift port must reproduce them

```
# run the tests (37)
python -m pytest engine -q

# regenerate demo traces + golden fixtures
python engine/scripts/generate.py

# watch the demo: map a studio apartment, then guide to the fridge
# while a person paces across the route (live D* Lite reroutes)
python -m http.server 8123
# -> open http://localhost:8123/tools/viewer/index.html
```

## Where it's going

| Milestone | Theme |
|---|---|
| M0.5 | Depth estimation + object detection prototyped on Windows (PyTorch/ONNX) |
| M1 | Mac + Xcode: ARKit shell, engine ported to Swift against the golden traces |
| M2 | LiDAR mesh provider, `ARWorldMap` persistence, named waypoints, house-scale room graph |
| M3 | Ariadne mode for real: haptic corridor, spatial-audio beacon, voice |
| M4 | On-device ML: monocular depth as pseudo-LiDAR on non-LiDAR phones, "go to the fridge" via detection |
| M5 | Learned steering: PPO policy trained in this sim, exported to Core ML, A/B'd against classical |

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
[docs/ROADMAP.md](docs/ROADMAP.md) · [learning/README.md](learning/README.md)

## Repo map

```
engine/     Python navigation core (the source of truth) + tests
fixtures/   room definitions, golden traces
tools/      viewer/ — zero-dependency HTML replay viewer for traces
learning/   ML lanes: depth, detection, RL steering, map inpainting
apps/ios/   Xcode project (arrives at M1)
docs/       architecture & roadmap
```

Personal learning project — built in the open, classical algorithms before
learned ones, everything replayable and tested.
