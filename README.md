<div align="center">
<img src="apps/ios/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="110" alt="Theseus icon">

# Theseus

**A home inventory app with a spatial brain** — scan rooms with an
iPhone, let AI name and value everything in them, and get
insurance-grade records out: claim PDFs, sealed move-in/out evidence,
QR-labeled storage boxes, and a map that knows where things are.

[![ci](https://github.com/anish-agr/theseus/actions/workflows/ci.yml/badge.svg)](https://github.com/anish-agr/theseus/actions/workflows/ci.yml)
[![ios](https://github.com/anish-agr/theseus/actions/workflows/ios.yml/badge.svg)](https://github.com/anish-agr/theseus/actions/workflows/ios.yml)

</div>

Under the app sits a **navigation engine written twice**: first as a
pure-Python, standard-library-only reference — property-tested, frozen
behind golden traces — then as a line-by-line Swift port that replays
those same traces frame-for-frame. On top of the engine, four ML lanes
(monocular depth, detection waypoints, PPO steering, map inpainting)
were trained and validated against real footage before any of them
touch a phone.

Two capability decisions define the project's shape:

- **No LiDAR required.** The perception stack is built for ordinary
  iPhones first — ARKit plane detection plus filtered feature points
  feed the occupancy model today, with monocular-depth pseudo-LiDAR as
  the designed upgrade. LiDAR mesh ingestion is an *addition*, not the
  baseline.
- **No Mac required.** The engine, tests, simulators, trace tooling,
  and ML lanes run anywhere Python runs, including Windows; the Swift
  engine port compiles and tests on Windows and Linux; and the iOS app
  itself is built by CI on cloud macOS runners, producing an
  installable IPA on every push ([docs/NO-MAC.md](docs/NO-MAC.md)).

<div align="center">
<img src="docs/media/guidance.png" width="640" alt="The trace viewer replaying the studio guidance demo: mapped walls and furniture, the smoothed route to the fridge, the agent en route, and a person pacing across the path">
<br><em>The engine's flagship demo, replayed in the zero-dependency
trace viewer: map a studio apartment, then guide to the fridge while a
person paces across the route — 7 live D* Lite reroutes, zero
collisions.</em>
</div>

> **Why "Theseus"?** In 1950 Claude Shannon built *Theseus*, a
> mechanical mouse that learned to solve a maze — arguably the first
> machine-learning demo in history. And in the myth, Theseus survives
> the labyrinth by following Ariadne's thread. This project is both:
> classical pathfinding first, learned behavior on top. The thread is
> also the app's entire design language.

## Two-minute tour

The engine and its demos need nothing but Python — no pip installs,
no GPU, no Apple hardware:

```bash
git clone https://github.com/anish-agr/theseus
cd theseus
python -m pytest engine learning -q     # 113 tests, ~90 s
python engine/scripts/generate.py       # regenerate all demo traces
python engine/scripts/showcase.py       # fit-through, exits, coverage, semantic queries
python -m http.server 8123              # then open:
#   http://localhost:8123/tools/viewer/index.html?trace=demo-trace.jsonl
#   ...?trace=explore-trace.jsonl   ?trace=walk-trace.jsonl   ?trace=depth-trace.jsonl
```

The iPhone app builds in CI — every push to `main` produces an
unsigned `Theseus.ipa` artifact under the
[ios workflow](https://github.com/anish-agr/theseus/actions/workflows/ios.yml),
installable with AltServer and a free Apple ID
([docs/INSTALL.md](docs/INSTALL.md)).

## The shape of the project

**One world model, many solvers.** Every feature — guide a person,
explore a room, "will this couch fit through the hallway", "find my
keys" — is a query over the same occupancy world model. Features never
talk to sensors and never own private maps:

```
scan  →  world model  →  solver  →  guidance / rendering
         (occupancy,      (A*, D* Lite, flow fields,
          clearance,       frontier, coverage, fit-through,
          semantics)       semantic queries)
```

That rule is enforced by the layering:

| layer | language | job |
|---|---|---|
| [`engine/`](engine/) | Python, **stdlib only** | the reference implementation — world model, planners, steering, guidance, FSM, deterministic simulator, trace writer |
| [`apps/navcore/`](apps/navcore/) | Swift package | the port — behaviorally identical, verified against Python-generated fixtures and golden traces |
| [`apps/ios/`](apps/ios/) | SwiftUI + ARKit | the shipped app — perception, product, and everything Apple |
| [`learning/`](learning/) | PyTorch et al. | ML lanes that feed the engine through existing seams |

The stdlib-only rule for `engine/` isn't asceticism: it guaranteed the
Swift port had no numpy-shaped dependencies to untangle, and it keeps
the reference runnable on any machine with Python — which is also what
makes the golden-trace discipline portable.

## The engine

The load-bearing decisions, briefly — each has a longer rationale as a
docstring at its definition site, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the full tour.

**World model** (`grid.py`) — a dense 2.5-D occupancy grid, 5–6 cm
cells, with *bounded* log-odds evidence. Bounding matters: with
unbounded accumulation, a corridor mapped free for ten minutes takes
ten minutes of contrary evidence to admit a person is now standing in
it; bounded at ±~2, it flips in about three observations. Alongside
occupancy: semantic labels, last-seen ticks, and a lazily-invalidated
**clearance field** — octile distance to the nearest occupied cell,
computed by multi-source Dijkstra, capped because nothing downstream
consumes clearance beyond ~1.2 m. The clearance field powers corridor-
width cues, steering admissibility, cost shaping, and fit-through
queries.

Three policies are load-bearing enough to be contracts:

- *Unknown space is a wall.* Guidance never routes a human through
  unseen space; mapping and exploration opt in explicitly via plan
  parameters.
- *Clearance measures occupied cells only* — unknown is already
  untraversable, and counting it would forbid perfectly good corridors
  that happen to run beside an unscanned wall.
- *One cost function.* `edge_cost` — path length × a cell cost that
  rises linearly as clearance drops below the safety margin — lives in
  exactly one place, and both planners consume it. The A*/D* Lite
  equivalence property tests depend on that; forking it is the
  project's cardinal sin.

**Planning** — A* is the optimal reference, property-tested against
Dijkstra; **D* Lite** is what ships. It searches backward from the
goal so the stable part of the search survives the agent moving;
`notify_changed` repairs only the region an edit touched; the k_m
offset trick makes start movement nearly free. Mid-route replans
measure in single-digit milliseconds *in interpreted Python* — the
demo reroutes around a walking person seven times without a full
replan. Its property test is the engine's keystone: across randomized
world edits and agent moves, D* Lite's path cost must equal a
from-scratch A* every time. Path smoothing is greedy shortcutting
whose corridors are verified traversable at the agent's body radius —
the output is the "thread" a person actually follows.

**Steering & guidance** — walk mode uses VFH-style sector scoring:
per-heading free distance from clearance-aware ray marching, scored by
openness, goal alignment, and heading-keeping, with explicit
**hysteresis** (previous-choice bonus, commit window, switch margin)
so cues never flap between two nearly-equal gaps. A BLOCKED outcome
escalates to the state machine instead of flailing. Guidance is
pure-pursuit over the smoothed path: a lookahead point ~0.9 m ahead
emits typed cues — `straight`, `turn left 43°`, `off_route`, `arrive`
— plus corridor width for haptic intensity. Geometry conventions
(meters, +y up, headings CCW, **positive bearing error = turn left**)
are pinned by dedicated sign tests, because a flipped sign here walks
a guided human into furniture.

**Safety gates, measured not assumed** — walk mode requires both
sensor freshness *and* a swept-body check against live cell states,
because of a measured coincidence: the clearance cache refreshes every
5 ticks, which is exactly long enough for a walking person to shift
one body width. The gate radius sits just under the body radius —
at the body radius, legal wall-skimming stalls the controller.

**The solver catalogue** — all over the same grid, all demonstrated in
`showcase.py`: Dijkstra **flow fields** from exits (evacuation mode:
follow the gradient from anywhere, no plan needed), boustrophedon
**coverage** sweeps, **frontier exploration** (the agent picks its own
viewpoints until no reachable unknown remains), **fit-through**
(sweep a rectangle along a route via the clearance field — finds the
real 0.60 m pinch point in the demo apartment), and **semantic
queries** ("nearest seat") with body-realistic approach points,
because the cell adjacent to a couch can never satisfy body clearance.

**Determinism as a feature** — the simulator (limited-FOV sensing,
moving obstacles, collision checks) is deterministic end-to-end; every
demo writes a JSONL trace; golden fixtures freeze behavior
byte-for-byte and are hash-checked in CI. Any intentional behavior
change shows up as a golden diff in review, and the same traces became
the acceptance tests for the Swift port.

<div align="center">
<img src="docs/media/explore.png" width="560" alt="Frontier exploration mid-run: the agent has discovered part of the studio; undiscovered space is still fogged">
<br><em>Frontier exploration mid-run — the agent maps until no
reachable unknown space remains. "Scan complete" in the app is this
solver saying so, never a percentage.</em>
</div>

## The Swift port

`apps/navcore` is the engine again, in Swift, and the parity contract
is mechanized rather than aspirational:
`engine/scripts/gen_swift_fixtures.py` makes the Python engine emit
(input, expected-output) batteries directly into the Swift test
target, so the port is tested against the reference's *actual
numbers*. 42 Swift tests culminate in golden replays: NavCore
re-simulates all three golden scenarios — guidance with live reroutes,
exploration, walk mode with safety gates — **frame-for-frame**. The
package has no Apple-only dependencies and builds on Linux in CI,
which is what keeps it honest.

Getting to frame parity surfaced the divergences that make
bit-faithful ports genuinely hard, all documented in
[docs/PORT.md](docs/PORT.md):

- Python's `round()` is banker's rounding; Swift's `.rounded()` is
  half-away-from-zero. Silent golden-replay failure.
- Python's float `//` is *neither* Swift truncation *nor*
  `floor(a/b)`: IEEE division rounds the quotient first, so
  `floor(0.5 / 0.05)` is `10` while Python's `0.5 // 0.05` is `9`.
  NavCore carries a port of CPython's `float_divmod`, found the hard
  way by parity fixtures.
- Python dicts iterate in insertion order and the engine leans on that
  determinism; Swift dictionaries don't, so every such site sorts or
  keeps arrays.
- Identical IEEE-754 results require identical *operation order* — the
  port preserves expression shapes rather than "equivalent" refactors,
  and heaps keep the same `(key, seq)` tie-breaking as Python's
  `heapq`.

## The app

<img src="apps/ios/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="72" align="right" alt="">

The product went through a real identity arc: it began as a navigation
app, and seven on-device field-test cycles reshaped it into an
**inventory app** — nobody rescans their home every day, so the
durable value is the *record*: what you own, what it's worth, what
condition the apartment was in at move-in. Navigation stayed as the
supporting act (point the camera, follow the beacon to your keys).

What ships in v1.1:

- **Scan → capture → batch AI.** Rooms are scanned with a lock-on
  capture (2.2 s dwell within ~5° steadiness, cooldown, point-away to
  re-arm) framed by a saliency-tracked bounding box, so a capture is a
  deliberate act instead of a hair trigger. Nothing interrupts a scan
  — no popups, no blocking calls. Afterwards, one batch pass
  identifies everything in multi-image requests: names, descriptions,
  categories, replacement values, per-item confidence.
- **Storage spots** — photograph the inside of a box from several
  angles and the vision model itemizes it, returning per-item bounding
  boxes (`box_2d`) so each item gets a cropped thumbnail out of the
  shelf photo. Printable QR labels deep-link back to the box's
  contents.
- **Insurance assistant** — serial-number OCR, receipt capture with
  on-device OCR (total and purchase date extracted locally),
  warranties, a claim-ready PDF, and a wizard that walks the whole
  house from scan to dossier.
- **Condition records** — sealed, SHA-256-hashed photo walkthroughs
  for move-in/move-out, with a comparison PDF built for deposit
  disputes: dated, tamper-evident photos.
- **Exports** — room report PDFs, floor-plan PNGs, inventory JSON,
  move manifests, a household snapshot, and a full off-device backup;
  the .zip writer is ~90 lines of store-method + CRC32 rather than a
  dependency.
- **Find things** — Core Spotlight indexing, App Intents, on-device
  voice commands ("mark this", "what is this", "find my keys"), and
  locate-in-camera: a beacon in AR with distance-scaled haptic ticks,
  route-aware via 1 Hz A* so the direction arrow never points through
  a wall.

**Performance engineering on a 2018-class SoC** was its own campaign,
and the lessons are written at the sites of their crimes:

- ARKit at 60 fps in a background tab thermal-throttles an A12 into
  system-wide jank. The session pauses whenever a scan isn't live and
  on-screen, frame handling is decimated to 30 Hz, and the RealityKit
  view drops motion blur, depth of field, HDR, and grain.
- One `@Published` pose at 60 Hz re-renders every subscribed SwiftUI
  view per camera frame. Publishing on change only (2 cm / 1° / 250 ms
  heartbeat) took the app from "choppy after a minute" to flat.
- The minimap was ~80k Canvas path-fills per frame; it's now a single
  CGImage blit, rasterized at 1 Hz. AR overlay entities rebuild on
  quantized keys with cached meshes.
- ARWorldMaps dominated disk, so they're LZFSE-compressed (~halved);
  thumbnails are NSCache'd at 512 px; per-row SwiftData queries were
  hoisted to parents after profiling list hitches.

**The AI layer** is provider-agnostic — Gemini, Claude, or any
OpenAI-compatible endpoint behind one interface, bring-your-own-key,
keys in the Keychain and sent only as headers. Photos leave the device
exclusively on an explicit user action; nothing uploads in the
background. The client is built for real-world API weather with a
self-healing call loop: retired model IDs trigger live model discovery
and re-selection; generation-dependent request knobs are dropped and
remembered when a backend rejects them; reasoning models that exhaust
their output budget before the first visible token get an automatic
retry at 4× the budget; rate limits are absorbed by parsing the
server's own retry-delay hint; overload errors back off and retry.
Batches pace themselves, partial results always survive a failed
chunk, and a status line reports every state — a long identify never
looks dead.

**The design system** is a single continuous thread ending in a
glowing dot ([docs/BRAND.md](docs/BRAND.md)): launch draws the thread
to the dot, loading states are the thread drawing itself (never a
spinner), success is one warm pulse (never a checkmark), errors go
cool blue (never red, never shaking). The app icon is generated from
the same Bézier path as the in-app logo, so the two can never drift.

## The ML lanes

All four lanes trained and validated CPU-only, against real footage —
full numbers and reproduce commands in
[learning/RESULTS.md](learning/RESULTS.md):

| lane | headline result |
|---|---|
| A — monocular depth → occupancy | real handheld video (TUM fr1_desk, mocap ground-truth poses) → coherent metric floor plan; **0/133** walked cells falsely blocked |
| B — detection → waypoints | fridge/ovens/table/chairs promoted from public clips through a merge/promote/decay registry, **zero ghost objects** |
| C — PPO steering | held-out success **0.90 / 0.90 / 0.87** vs scripted baseline 0.60 / 0.37 / 0.30 as movers increase — the learned edge *grows* with scene dynamics; exported to a verified 78 KiB ONNX (256/256 action parity, held-out metrics reproduced by the exported artifact itself) |
| D — map inpainting | UNet beats nearest-known baseline on held-out rooms: acc **0.844** vs 0.770, IoU_occ **0.587** vs 0.388 — strictly advisory, predicted cells are never traversable |

<div align="center">
<img src="docs/media/depth-tum.png" width="480" alt="Occupancy map recovered from real handheld footage of the TUM fr1_desk sequence">
<br><em>Lane A on real footage: an occupancy map recovered from
handheld video of a desk scene (TUM fr1_desk), using per-frame affine
fits in inverse depth — the role ARKit feature points play
on-device.</em>
</div>

Two methodological details worth flagging. Monocular depth is affine
in *inverse* depth, so metric alignment fits `1/z = s·r + t` per frame
against sparse anchors — fitting plain depth looks fine on a wall and
falls apart down a corridor. And the RL reward is potential-based
shaping (provably optimality-preserving) on the flow-field geodesic —
a dense gradient every step, computed by literally the same solver the
engine uses for evacuation routes; evaluation is success rate plus SPL
against the true shortest path, on seed ranges disjoint from training.

## Building an iPhone app entirely in CI

The repository contains no generated Xcode project — the entire app
definition is a declarative XcodeGen spec, and the pipeline
([docs/NO-MAC.md](docs/NO-MAC.md), [docs/INSTALL.md](docs/INSTALL.md))
runs end-to-end without local Apple hardware:

1. `apps/ios/project.yml` → XcodeGen generates the `.xcodeproj` in CI,
   deterministically, with an explicit Info.plist (auto-generated
   plists silently omit `CFBundleIconName` and fail App Store
   validation with ITMS-90713 — the kind of landmine that only shows
   up when the pipeline is fully scripted).
2. `ios.yml` builds on macOS runners and uploads an unsigned
   `Theseus.ipa` artifact per push; `ci.yml` runs the Python suite and
   builds + tests the Swift engine on Linux, which also proves NavCore
   never quietly grows an Apple-only dependency.
3. AltServer signs and sideloads the artifact with a free Apple ID;
   `testflight.yml` covers the signed distribution route, including
   generating the Apple signing certificate from any OS with OpenSSL.
4. Field-test cycles replace the debugger: build in the cloud,
   sideload, observe, write the verdict into the docs, fix. Seven
   cycles and six releases shipped this way (v0.2 → v1.1).

## Repo map

```
engine/      Python navigation core (the reference) + 90 tests
apps/
  navcore/   Swift port, parity fixtures, golden replay tests
  ios/       the app: SwiftUI + SwiftData + ARKit, XcodeGen spec
learning/    ML lanes A–D, results, trained-model runners
fixtures/    room definitions + golden traces (hashed in CI)
tools/
  viewer/    zero-dependency HTML trace replay viewer
  icon/      app icon generator (same path as the in-app logo)
  ci/        IPA validator, PowerShell lint
docs/        architecture, port guide, requirements, roadmap,
             brand spec, install routes, feature ledger
.github/     ci.yml (engine + NavCore on Linux) · ios.yml (cloud
             macOS build) · testflight.yml (optional signed route)
```

## Where it's going

Near-term: LiDAR mesh ingestion and house-scale room graphs with
hierarchical planning (M2), on-device monocular depth as pseudo-LiDAR
for non-LiDAR phones (M4), and the trained steering policy behind the
engine's `SteeringPolicy` seam with a live classical-vs-learned A/B
toggle (M5). The full gated roadmap with acceptance criteria:
[docs/ROADMAP.md](docs/ROADMAP.md) · honest status ledger:
[docs/CHECKLIST.md](docs/CHECKLIST.md).

Built in the open — classical algorithms before learned ones,
everything replayable, every behavior change visible in a golden diff.

## License

[MIT](LICENSE)
