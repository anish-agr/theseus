# Porting the engine to Swift (milestone M1)

Goal: a SwiftPM package `NavCore` that is **behaviorally identical** to
`engine/` — proven by porting each module's tests first, then replaying
the golden scenarios. The Python engine stays the reference; divergence
is a bug in the port until proven otherwise.

## Order (dependency order — port tests first, module second)

| # | module | notes |
|---|--------|-------|
| 1 | geometry | pure math; `Vec = SIMD2<Double>` (stdlib SIMD, cross-platform — NOT Apple's `simd` module) |
| 2 | grid | the heart; port docstring policies as doc comments — they are contracts |
| 3 | astar | needs a binary heap (see below) |
| 4 | dstar_lite | the subtle one; the A*-equivalence property test is the safety net |
| 5 | flowfield, frontier, coverage, queries | straightforward once 2–3 land |
| 6 | steering, guidance, fsm | guidance sign tests are non-negotiable |
| 7 | waypoints, serialize, trace | trace: see float note |
| 8 | sim, controller | sim is test-infrastructure; controller becomes the actor pipeline |

## Type mapping

| Python | Swift |
|--------|-------|
| `tuple[float, float]` (Vec) | `SIMD2<Double>` |
| `tuple[int, int]` (Cell) | `struct Cell: Hashable { var x, y: Int32 }` |
| `list[float]` grid fields | `[Double]` (contiguous, same idx math) |
| `dict[int, str]` labels | `[Int32: String]` |
| `heapq` | hand-rolled binary heap with `(key, seq)` tie-break — do NOT use a library heap with different tie-breaking |
| `dataclass` | `struct` |
| `Protocol` (SteeringPolicy) | `protocol` |
| `float('inf')` | `Double.infinity` |

## Landmines (each one is a real divergence risk)

1. **Banker's rounding.** Python `round(x, 4)` rounds half-to-even.
   Swift: `(x * 1e4).rounded(.toNearestOrEven) / 1e4`. Using
   `.rounded()` (half-away-from-zero) will silently fail golden replay.
2. **Golden comparison level.** Compare traces at PARSED-FRAME level
   with exact numeric equality after rounding — not byte level. Python's
   shortest-round-trip float repr and Swift's `Double.description` agree
   on most values but not certainly on all formatting (exponents etc.).
   The byte-hash goldens remain the Python-side regression; the port's
   contract is: same frames, same numbers, same order.
3. **Floor division.** `world_to_cell` uses Python `//` (floor). Swift
   integer conversion truncates toward zero — use
   `Int((p.x / cell).rounded(.down))`. Negative coordinates will bite
   you exactly once if you forget.
4. **Iteration order.** Python dicts iterate in insertion order and the
   code exploits determinism everywhere (sorted seeds in frontier
   clustering, `neighbors8` fixed offset order, seq tie-breaks in
   heaps). Preserve orders exactly; Swift `Dictionary` iteration order
   is NOT insertion order — sort where the Python sorts, and keep
   arrays where the Python relies on order.
5. **Float determinism.** Same IEEE-754 double ops in the same order
   give identical results — so keep operation ORDER identical (e.g.
   `step * cs * 0.5 * (ca + cb)`, not a refactored equivalent).
6. **No Foundation in NavCore.** Keeps it portable and fast; JSON for
   trace/serialize can live in a small adjacent target that IS allowed
   Foundation.
7. **`wrap_angle` via atan2(sin, cos)** — port it literally; clever
   fmod-based versions differ at ±π.

## Process per module

1. Port the module's test file to swift-testing, mechanical translation.
2. Port the module until tests pass.
3. After modules 1–8: golden replay — run mini / mini-explore /
   mini-walk scenarios in Swift, compare frame streams against
   `fixtures/golden/*-trace.jsonl` (parsed comparison, rule 2).
4. Only then wire ARKit (`apps/ios/README.md` has the target layout).

## What does NOT get ported

- `learning/` (Python stays the training side; models cross over as
  Core ML artifacts behind existing seams: `SteeringPolicy`, the
  perception provider protocol, the advisory inpainter).
- `engine/scripts/`, viewer, fixtures generation — Windows/CI tooling.
