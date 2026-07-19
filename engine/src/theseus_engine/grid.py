"""Occupancy world model: a dense 2.5D grid over one floor.

Each cell holds a log-odds occupancy estimate, an optional semantic label
and a last-seen tick. Three derived states (UNKNOWN / FREE / OCCUPIED)
drive planning. A clearance field (octile distance in meters to the
nearest OCCUPIED cell) supports safety margins, cost shaping, steering
and "will-it-fit" queries.

Design decisions the Swift port must preserve exactly (they are baked
into the golden fixtures):

- Unknown space is NOT traversable by default. The hero use case guides a
  human, so we never route through space we have not seen. Mapping and
  explore modes opt in with PlanParams(unknown_ok=True).
- Clearance measures distance to OCCUPIED cells only. Unknown cells are
  already untraversable themselves; counting them would forbid walking a
  known-free corridor that runs beside an unscanned wall.
- No ambient decay: mapped cells persist until re-observed. A stale
  "the mover was here" cell is exactly what forces D* Lite to replan,
  and re-observation clears it.
- Edge costs are directed: an edge requires its DESTINATION to be fully
  traversable (state + clearance), but its SOURCE only to be
  non-occupied. Wherever the agent actually stands is a fact, not a
  planning choice — without this rule an agent standing closer to a wall
  than the safety radius could never plan its way out.
- Diagonal moves must not cut corners: both shared cardinal neighbors
  have to be passable.
"""

from __future__ import annotations

import heapq
from dataclasses import dataclass

from .geometry import Cell, INF, SQRT2, Vec

UNKNOWN, FREE, OCCUPIED = 0, 1, 2

LO_HIT = 0.85       # log-odds increment for an "occupied" observation
LO_MISS = -0.6      # log-odds increment for a "free" observation
# Bounded log-odds (standard practice for dynamic environments): saturation
# limits how much contrary evidence is needed before a cell flips, so a
# long-free corridor registers a person stepping into it within ~3
# observations instead of ~6.
LO_MIN, LO_MAX = -1.8, 2.5
LO_OCC, LO_FREE = 0.7, -0.7   # state thresholds

# (dx, dy, step length in cells)
_OFFSETS = (
    (1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
    (1, 1, SQRT2), (1, -1, SQRT2), (-1, 1, SQRT2), (-1, -1, SQRT2),
)


@dataclass(frozen=True)
class PlanParams:
    """Canonical cost/safety model shared by A*, D* Lite, steering and
    smoothing. Both planners MUST see identical costs — the A*/D* Lite
    equivalence property tests depend on it."""
    radius: float = 0.30        # body radius (m); human ~0.28-0.35
    safe_margin: float = 0.55   # clearance below which cost rises (m)
    margin_weight: float = 1.5  # extra cost multiplier at zero clearance
    unknown_ok: bool = False    # may we traverse unseen cells?


class OccupancyGrid:
    def __init__(self, width: int, height: int, cell_size: float,
                 origin: Vec = (0.0, 0.0)):
        if width <= 0 or height <= 0:
            raise ValueError("grid dimensions must be positive")
        self.width = width
        self.height = height
        self.cell_size = cell_size
        self.origin = origin
        n = width * height
        self.lo = [0.0] * n
        self.last_seen = [-1] * n
        self.labels: dict[int, str] = {}
        # Clearance cache. clearance_cap (meters) bounds how far the
        # distance transform expands — anything farther just reads as the
        # cap, which is fine as long as the cap exceeds every consumer's
        # threshold (safe_margin, radius). auto_clearance=False lets a
        # simulation throttle recomputes via refresh_clearance() and
        # tolerate a few ticks of staleness.
        self._clearance: list[float] | None = None  # meters; lazy
        self._clear_dirty = True
        self.clearance_cap: float | None = None
        self.auto_clearance = True

    @classmethod
    def from_meters(cls, width_m: float, height_m: float, cell_size: float,
                    origin: Vec = (0.0, 0.0)) -> "OccupancyGrid":
        return cls(round(width_m / cell_size), round(height_m / cell_size),
                   cell_size, origin)

    # ---- indexing -------------------------------------------------------

    def idx(self, c: Cell) -> int:
        return c[1] * self.width + c[0]

    def in_bounds(self, c: Cell) -> bool:
        return 0 <= c[0] < self.width and 0 <= c[1] < self.height

    def world_to_cell(self, p: Vec) -> Cell:
        return (int((p[0] - self.origin[0]) // self.cell_size),
                int((p[1] - self.origin[1]) // self.cell_size))

    def cell_center(self, c: Cell) -> Vec:
        return (self.origin[0] + (c[0] + 0.5) * self.cell_size,
                self.origin[1] + (c[1] + 0.5) * self.cell_size)

    # ---- state ----------------------------------------------------------

    def state(self, c: Cell) -> int:
        """Out-of-bounds reads as OCCUPIED: the world ends in a wall."""
        if not self.in_bounds(c):
            return OCCUPIED
        lo = self.lo[self.idx(c)]
        if lo >= LO_OCC:
            return OCCUPIED
        if lo <= LO_FREE:
            return FREE
        return UNKNOWN

    def blocked(self, c: Cell, unknown_ok: bool) -> bool:
        s = self.state(c)
        return s == OCCUPIED or (s == UNKNOWN and not unknown_ok)

    def label(self, c: Cell) -> str:
        return self.labels.get(self.idx(c), "")

    def set_state(self, c: Cell, state: int, label: str = "") -> bool:
        """Direct write for simulators and tests. Returns True if the
        derived state changed."""
        if not self.in_bounds(c):
            return False
        before = self.state(c)
        i = self.idx(c)
        self.lo[i] = {UNKNOWN: 0.0, FREE: LO_MIN, OCCUPIED: LO_MAX}[state]
        # (uses the saturation values, so set_state and repeated observe()
        # calls converge to identical log-odds)
        if label:
            self.labels[i] = label
        after = self.state(c)
        if (before == OCCUPIED) != (after == OCCUPIED):
            self._clear_dirty = True  # only the occupied set shapes clearance
        return after != before

    def observe(self, c: Cell, occupied: bool, tick: int = 0,
                label: str = "") -> bool:
        """Bayesian log-odds update from one sensor reading. Returns True
        if the derived state changed (planners need to know)."""
        if not self.in_bounds(c):
            return False
        i = self.idx(c)
        before = self.state(c)
        lo = self.lo[i] + (LO_HIT if occupied else LO_MISS)
        self.lo[i] = max(LO_MIN, min(LO_MAX, lo))
        self.last_seen[i] = tick
        if occupied and label:
            self.labels[i] = label
        after = self.state(c)
        if (before == OCCUPIED) != (after == OCCUPIED):
            self._clear_dirty = True
        return after != before

    def neighbors8(self, c: Cell):
        """Yields (neighbor, step_length_in_cells) for in-bounds neighbors."""
        x, y = c
        for dx, dy, step in _OFFSETS:
            n = (x + dx, y + dy)
            if 0 <= n[0] < self.width and 0 <= n[1] < self.height:
                yield n, step

    # ---- clearance field --------------------------------------------------

    def clearance(self, c: Cell) -> float:
        """Octile-metric distance in meters from this cell to the nearest
        OCCUPIED cell (0.0 for occupied cells, INF if no obstacle exists).
        Computed lazily over the whole grid and cached until any cell's
        derived state changes."""
        if not self.in_bounds(c):
            return 0.0
        if self._clearance is None or (self._clear_dirty and self.auto_clearance):
            self._compute_clearance()
        return self._clearance[self.idx(c)]

    def refresh_clearance(self, force: bool = False) -> None:
        """Recompute the clearance field now if it is stale (or `force`).
        Simulations with auto_clearance=False call this on their own cadence."""
        if force or self._clearance is None or self._clear_dirty:
            self._compute_clearance()

    def _compute_clearance(self) -> None:
        # Multi-source Dijkstra from every occupied cell, expanding with
        # 1 / sqrt(2) step weights: yields the exact octile distance
        # transform (obstacles do not occlude it; the wave crosses cells
        # freely). Octile >= euclidean never underestimates by more than
        # ~8%, which is fine for safety margins at 5 cm resolution.
        n = self.width * self.height
        cs = self.cell_size
        cap = INF if self.clearance_cap is None else self.clearance_cap / cs
        dist = [cap] * n
        heap: list[tuple[float, int, int]] = []
        for y in range(self.height):
            base = y * self.width
            for x in range(self.width):
                i = base + x
                if self.lo[i] >= LO_OCC:
                    dist[i] = 0.0
                    heap.append((0.0, x, y))
        heapq.heapify(heap)
        while heap:
            d, x, y = heapq.heappop(heap)
            i = y * self.width + x
            if d > dist[i]:
                continue
            for dx, dy, step in _OFFSETS:
                nx, ny = x + dx, y + dy
                if 0 <= nx < self.width and 0 <= ny < self.height:
                    ni = ny * self.width + nx
                    nd = d + step
                    if nd < dist[ni] and nd < cap:
                        dist[ni] = nd
                        heapq.heappush(heap, (nd, nx, ny))
        self._clearance = [d * cs for d in dist]
        self._clear_dirty = False

    def min_clearance_along(self, a: Vec, b: Vec, sample: float = 0.5) -> float:
        """Smallest clearance along the straight segment a-b (world coords).
        This is the kernel of the future "will this couch fit through the
        hallway" solver: a corridor admits width w iff the result >= w/2."""
        from .geometry import dist as vdist
        length = vdist(a, b)
        steps = max(1, int(length / (self.cell_size * sample)))
        best = INF
        for k in range(steps + 1):
            t = k / steps
            p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            best = min(best, self.clearance(self.world_to_cell(p)))
        return best

    # ---- canonical cost model ---------------------------------------------

    def traversable(self, c: Cell, p: PlanParams) -> bool:
        return (not self.blocked(c, p.unknown_ok)
                and self.clearance(c) >= p.radius)

    def cell_cost(self, c: Cell, p: PlanParams) -> float:
        """>= 1.0 everywhere; rises linearly as clearance drops below
        safe_margin, so planners prefer corridor centers without
        forbidding tight-but-legal passages."""
        cl = self.clearance(c)
        if cl >= p.safe_margin:
            return 1.0
        return 1.0 + p.margin_weight * (p.safe_margin - cl) / p.safe_margin

    def edge_cost(self, a: Cell, b: Cell, p: PlanParams) -> float:
        """Directed cost of moving a -> b, INF if the move is illegal.
        The single cost function shared by A*, D* Lite and smoothing."""
        if not self.in_bounds(a) or not self.in_bounds(b):
            return INF
        if self.state(a) == OCCUPIED:
            return INF
        if not self.traversable(b, p):
            return INF
        dx, dy = b[0] - a[0], b[1] - a[1]
        if dx != 0 and dy != 0:
            # no corner cutting: both shared cardinal cells must be passable
            if self.blocked((a[0] + dx, a[1]), p.unknown_ok):
                return INF
            if self.blocked((a[0], a[1] + dy), p.unknown_ok):
                return INF
            step = SQRT2
        else:
            step = 1.0
        return step * self.cell_size * 0.5 * (self.cell_cost(a, p) + self.cell_cost(b, p))
