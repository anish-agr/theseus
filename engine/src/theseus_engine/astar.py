"""A* on the occupancy grid — the optimal reference planner.

A* here plays two roles: it is the planner used in mapping/explore mode
(where full replans are rare), and it is the ground truth that the
incremental planner (dstar_lite.py) is property-tested against: for any
sequence of world edits, D* Lite's path must cost exactly the same as a
fresh A* plan.

Also home to path smoothing: grid paths are staircases; `smooth()` pulls
them into the shortest sequence of straight segments whose entire corridor
stays traversable at the agent's radius.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from heapq import heappop, heappush

from .geometry import Cell, INF, Vec, dist, octile
from .grid import OccupancyGrid, PlanParams, OCCUPIED


@dataclass
class PlanResult:
    cells: list[Cell]
    cost: float


def plan(grid: OccupancyGrid, start: Cell, goal: Cell, params: PlanParams,
         use_heuristic: bool = True) -> PlanResult | None:
    """Optimal path start -> goal under grid.edge_cost, or None.
    With use_heuristic=False this is plain Dijkstra (used in tests as an
    independent optimality oracle)."""
    if not grid.in_bounds(start) or grid.state(start) == OCCUPIED:
        return None
    if not grid.traversable(goal, params):
        return None
    if start == goal:
        return PlanResult([start], 0.0)

    cs = grid.cell_size

    def h(c: Cell) -> float:
        # octile * cell_size * (min cell cost = 1.0): admissible & consistent
        return octile(c, goal) * cs if use_heuristic else 0.0

    g: dict[Cell, float] = {start: 0.0}
    parent: dict[Cell, Cell] = {}
    seq = 0
    heap: list[tuple[float, float, int, Cell]] = [(h(start), 0.0, seq, start)]
    while heap:
        _f, g_u, _, u = heappop(heap)
        if g_u > g.get(u, INF) + 1e-12:
            continue  # stale entry
        if u == goal:
            cells = [u]
            while u != start:
                u = parent[u]
                cells.append(u)
            cells.reverse()
            return PlanResult(cells, g_u)
        for v, _step in grid.neighbors8(u):
            c = grid.edge_cost(u, v, params)
            if c == INF:
                continue
            ng = g_u + c
            if ng < g.get(v, INF) - 1e-12:
                g[v] = ng
                parent[v] = u
                seq += 1
                heappush(heap, (ng + h(v), ng, seq, v))
    return None


def path_cost(grid: OccupancyGrid, cells: list[Cell], params: PlanParams) -> float:
    total = 0.0
    for i in range(len(cells) - 1):
        c = grid.edge_cost(cells[i], cells[i + 1], params)
        if c == INF:
            return INF
        total += c
    return total


def path_valid(grid: OccupancyGrid, cells: list[Cell], params: PlanParams) -> bool:
    """Cheap per-tick check that a previously planned path is still legal
    (the first cell is where the agent stands, so only source rules apply)."""
    if not cells:
        return False
    return path_cost(grid, cells, params) < INF


# ---- smoothing ------------------------------------------------------------

def corridor_clear(grid: OccupancyGrid, a: Vec, b: Vec, params: PlanParams,
                   sample: float = 0.4) -> bool:
    """True if every sampled cell along segment a-b is traversable at the
    agent radius. Fine sampling (default: 0.4 cells) also rules out the
    diagonal corner-cutting cases the edge model forbids."""
    length = dist(a, b)
    steps = max(1, int(math.ceil(length / (grid.cell_size * sample))))
    for k in range(steps + 1):
        t = k / steps
        p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        if not grid.traversable(grid.world_to_cell(p), params):
            return False
    return True


def smooth(grid: OccupancyGrid, cells: list[Cell], params: PlanParams) -> list[Vec]:
    """Greedy shortcut smoothing ("string pulling lite"): from each anchor,
    jump to the farthest path point whose straight corridor is clear.
    Output is world-space waypoints; endpoints are preserved."""
    pts = [grid.cell_center(c) for c in cells]
    if len(pts) < 3:
        return pts
    out = [pts[0]]
    i = 0
    while i < len(pts) - 1:
        j = len(pts) - 1
        while j > i + 1 and not corridor_clear(grid, pts[i], pts[j], params):
            j -= 1
        out.append(pts[j])
        i = j
    return out
