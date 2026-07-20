"""Flow fields: cost-to-nearest-goal for EVERY cell from one Dijkstra sweep.

A planner query answers one route; a flow field answers "from anywhere,
which way?" for a whole goal SET. That makes it the engine's workhorse
for:

- evacuation mode: goals = exit cells; from any point in the house the
  descent direction is the safe way out (works even with eyes closed —
  the field exists before you ask);
- nearest-semantic queries ("closest seat"): goals = every approach cell
  of every matching object (see queries.py);
- any "distance to the nearest X" ranking problem.

It shares the canonical grid.edge_cost with A*/D* Lite, and like D* Lite
it computes costs *toward* the goals: the relaxation pulls dist[u] from
dist[v] via edge_cost(u, v) — u is the cell farther from the goal — so
the directed source/destination rules are honored exactly. Property
tests pin distance(start) == A* cost for the single-goal case.
"""

from __future__ import annotations

import heapq
from typing import Iterable

from .astar import PlanResult
from .geometry import Cell, INF
from .grid import OccupancyGrid, PlanParams


class FlowField:
    def __init__(self, grid: OccupancyGrid, params: PlanParams,
                 dist: list[float]):
        self.grid = grid
        self.params = params
        self._dist = dist

    @classmethod
    def build(cls, grid: OccupancyGrid, goals: Iterable[Cell],
              params: PlanParams) -> "FlowField":
        """Multi-source Dijkstra seeded at every traversable goal cell."""
        n = grid.width * grid.height
        dist = [INF] * n
        heap: list[tuple[float, int, Cell]] = []
        seq = 0
        for g in goals:
            if grid.in_bounds(g) and grid.traversable(g, params):
                i = grid.idx(g)
                if dist[i] > 0.0:
                    dist[i] = 0.0
                    heap.append((0.0, seq, g))
                    seq += 1
        heapq.heapify(heap)
        while heap:
            d, _, v = heapq.heappop(heap)
            if d > dist[grid.idx(v)] + 1e-12:
                continue  # stale entry
            for u, _step in grid.neighbors8(v):
                c = grid.edge_cost(u, v, params)
                if c == INF:
                    continue
                nd = d + c
                iu = grid.idx(u)
                if nd < dist[iu] - 1e-12:
                    dist[iu] = nd
                    heapq.heappush(heap, (nd, seq, u))
                    seq += 1
        return cls(grid, params, dist)

    def distance(self, c: Cell) -> float:
        """Cost of walking from `c` to the nearest goal (INF if cut off)."""
        if not self.grid.in_bounds(c):
            return INF
        return self._dist[self.grid.idx(c)]

    def next_step(self, c: Cell) -> Cell | None:
        """The neighbor lying on a cheapest route to a goal, or None if
        `c` is a goal / unreachable."""
        d_here = self.distance(c)
        if d_here == 0.0 or d_here == INF:
            return None
        best: Cell | None = None
        best_d = INF
        for v, _step in self.grid.neighbors8(c):
            cost = self.grid.edge_cost(c, v, self.params)
            if cost == INF:
                continue
            d = cost + self.distance(v)
            if d < best_d:
                best, best_d = v, d
        return best

    def route_from(self, start: Cell) -> PlanResult | None:
        """Greedy descent from `start` to the nearest goal. Each step
        strictly decreases the remaining distance (edge costs are
        positive), so this terminates with an optimal route."""
        d0 = self.distance(start)
        if d0 == INF:
            return None
        cells = [start]
        c = start
        limit = self.grid.width * self.grid.height
        while self.distance(c) > 0.0 and len(cells) <= limit:
            nxt = self.next_step(c)
            if nxt is None or self.distance(nxt) >= self.distance(c):
                return None  # defensive: field not converged / start occupied
            cells.append(nxt)
            c = nxt
        return PlanResult(cells, d0) if self.distance(c) == 0.0 else None
