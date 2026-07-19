"""D* Lite — incremental replanning (Koenig & Likhachev, AAAI 2002).

Why this algorithm is the heart of Theseus: the world model changes every
few sensor ticks (a person walks through the corridor, a door opens, a
chair moves). Replanning from scratch with A* on every change wastes work;
D* Lite repairs only the part of the search affected by the change, and it
searches BACKWARD from the goal so that the agent moving (= the start
changing) is also cheap, handled by the km "key modifier" trick instead of
recomputing heuristics for the whole queue.

Invariants worth knowing when reading this file:
  g(u)   = best known cost from u to the GOAL (backward search)
  rhs(u) = one-step lookahead of g(u): min over successors s of
           c(u, s) + g(s); rhs(goal) = 0
  A vertex is "consistent" when g == rhs. The queue holds exactly the
  inconsistent vertices, ordered by calculate_key(). When
  compute_shortest_path() finishes, following the greedy successor
  argmin(c(u,s) + g(s)) from the start yields an optimal path.

This implementation recomputes rhs values exactly (a full min over
successors) instead of the paper's incremental shortcuts. It costs a few
extra neighbor evaluations per touched vertex and in exchange removes the
subtlest class of D* Lite bugs. The A*-equivalence property tests in
tests/test_dstar_lite.py are the safety net for the Swift port.

The priority queue uses lazy deletion: `entry[u]` remembers the sequence
number of u's latest valid heap entry; anything else popped is stale and
skipped.
"""

from __future__ import annotations

from heapq import heappop, heappush

from .geometry import Cell, INF, octile
from .grid import OccupancyGrid, PlanParams
from .astar import PlanResult

_EPS = 1e-9

Key = tuple[float, float]


class DStarLite:
    def __init__(self, grid: OccupancyGrid, start: Cell, goal: Cell,
                 params: PlanParams):
        self.grid = grid
        self.params = params
        self.start = start
        self.goal = goal
        self.km = 0.0
        self.s_last = start
        self.g: dict[Cell, float] = {}
        self.rhs: dict[Cell, float] = {goal: 0.0}
        self._heap: list[tuple[float, float, int, Cell]] = []
        self._entry: dict[Cell, int | None] = {}
        self._seq = 0
        self._push(goal)

    # ---- small accessors ----------------------------------------------

    def _gv(self, u: Cell) -> float:
        return self.g.get(u, INF)

    def _rhsv(self, u: Cell) -> float:
        return self.rhs.get(u, INF)

    def _h(self, u: Cell) -> float:
        return octile(self.start, u) * self.grid.cell_size

    def _key(self, u: Cell) -> Key:
        v = min(self._gv(u), self._rhsv(u))
        if v == INF:
            return (INF, INF)
        return (v + self._h(u) + self.km, v)

    # ---- lazy-deletion priority queue -----------------------------------

    def _push(self, u: Cell) -> None:
        k = self._key(u)
        self._seq += 1
        self._entry[u] = self._seq
        heappush(self._heap, (k[0], k[1], self._seq, u))

    def _invalidate(self, u: Cell) -> None:
        self._entry[u] = None

    def _top_key(self) -> Key:
        while self._heap and self._entry.get(self._heap[0][3]) != self._heap[0][2]:
            heappop(self._heap)
        if not self._heap:
            return (INF, INF)
        return (self._heap[0][0], self._heap[0][1])

    def _pop(self) -> tuple[Key, Cell] | None:
        while self._heap:
            k1, k2, seq, u = heappop(self._heap)
            if self._entry.get(u) == seq:
                self._entry[u] = None
                return (k1, k2), u
        return None

    def _update_vertex(self, u: Cell) -> None:
        if abs(self._gv(u) - self._rhsv(u)) > _EPS:
            self._push(u)
        else:
            self._invalidate(u)

    def _recompute_rhs(self, u: Cell) -> None:
        if u == self.goal:
            self._update_vertex(u)
            return
        best = INF
        for v, _step in self.grid.neighbors8(u):
            c = self.grid.edge_cost(u, v, self.params)
            if c == INF:
                continue
            cand = c + self._gv(v)
            if cand < best:
                best = cand
        self.rhs[u] = best
        self._update_vertex(u)

    # ---- core -----------------------------------------------------------

    def _compute_shortest_path(self) -> None:
        guard = 0
        limit = 40 * self.grid.width * self.grid.height  # safety net only
        while True:
            guard += 1
            if guard > limit:
                raise RuntimeError("D* Lite failed to converge (bug)")
            top = self._top_key()
            ks = self._key(self.start)
            start_consistent = abs(self._rhsv(self.start) - self._gv(self.start)) <= _EPS
            if not (top < ks) and start_consistent:
                break
            popped = self._pop()
            if popped is None:
                break
            k_old, u = popped
            k_new = self._key(u)
            if k_old < k_new:
                # key went stale (km grew or costs changed): reorder, don't process
                self._push(u)
                continue
            gu, ru = self._gv(u), self._rhsv(u)
            if gu > ru + _EPS:
                # overconsistent: this g value is now final
                self.g[u] = ru
                for s, _step in self.grid.neighbors8(u):
                    self._recompute_rhs(s)
            else:
                # underconsistent: invalidate and let the wave repair it
                self.g[u] = INF
                self._recompute_rhs(u)
                for s, _step in self.grid.neighbors8(u):
                    self._recompute_rhs(s)

    def plan(self) -> PlanResult | None:
        """(Re)compute and extract the current optimal path start -> goal."""
        self._compute_shortest_path()
        if self._gv(self.start) == INF:
            return None
        cells = [self.start]
        cost = 0.0
        u = self.start
        cap = self.grid.width * self.grid.height + 1
        while u != self.goal:
            best_v: Cell | None = None
            best = INF
            for v, _step in self.grid.neighbors8(u):
                c = self.grid.edge_cost(u, v, self.params)
                if c == INF:
                    continue
                cand = c + self._gv(v)
                if cand < best - _EPS:
                    best = cand
                    best_v = v
                    best_c = c
            if best_v is None or best == INF:
                return None
            cost += best_c
            u = best_v
            cells.append(u)
            if len(cells) > cap:
                return None  # should be unreachable once converged
        return PlanResult(cells, cost)

    # ---- world interface --------------------------------------------------

    def update_start(self, new_start: Cell) -> None:
        """Call whenever the agent's cell changes. km absorbs the heuristic
        drift so stale queue keys stay comparable (the D* Lite trick)."""
        if new_start == self.start:
            return
        self.km += self._h(new_start)  # h is measured from current start: octile(start, new)
        self.start = new_start
        self.s_last = new_start

    def notify_changed(self, cells) -> None:
        """Call with every cell whose derived state changed. Edge costs
        depend only on the two endpoint cells plus (for diagonals) their
        shared cardinal neighbors, all of which lie within distance 1 of a
        changed cell — so recomputing rhs for the changed cells and their
        8-neighborhoods repairs every affected edge."""
        affected: set[Cell] = set()
        for c in cells:
            c = tuple(c)
            if not self.grid.in_bounds(c):
                continue
            affected.add(c)
            for v, _step in self.grid.neighbors8(c):
                affected.add(v)
        for u in affected:
            self._recompute_rhs(u)
