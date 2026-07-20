"""Coverage routes: visit ALL reachable floor, not one goal.

Boustrophedon ("as the ox plows") sweep: pick vertical lanes spaced
lane_width apart, walk each lane's reachable runs alternately up and
down, and hop between runs with A*. Use cases: patrol mode, "sweep the
house for my keys" (pair with the detector), vacuum-style coverage.

The guarantee is practical, not perfect: pockets narrower than the lane
spacing can slip between lanes. coverage_fraction() reports honestly
what fraction of reachable floor the route passes within lane_width of —
demos and tests assert on that number instead of pretending.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass

from . import astar
from .geometry import Cell
from .grid import OccupancyGrid, PlanParams


@dataclass
class CoverageResult:
    cells: list[Cell]        # the full walkable route, start included
    visit_points: list[Cell]  # sweep waypoints in visiting order
    lanes: int
    skipped: int             # sweep points no route could reach


def _reachable(grid: OccupancyGrid, start: Cell,
               params: PlanParams) -> set[Cell]:
    """Cells reachable from start under the canonical edge rules."""
    if not grid.in_bounds(start):
        return set()
    seen = {start}
    q = deque([start])
    while q:
        u = q.popleft()
        for v, _step in grid.neighbors8(u):
            if v not in seen and grid.edge_cost(u, v, params) < float("inf"):
                seen.add(v)
                q.append(v)
    return seen


def coverage_route(grid: OccupancyGrid, start: Cell, params: PlanParams,
                   lane_width: float = 0.6) -> CoverageResult | None:
    reach = _reachable(grid, start, params)
    if not reach:
        return None
    lane_step = max(1, round(lane_width / grid.cell_size))
    visit: list[Cell] = []
    lanes = 0
    upward = True
    for x in range(lane_step // 2, grid.width, lane_step):
        ys = sorted(y for (cx, y) in reach if cx == x)
        if not ys:
            continue
        lanes += 1
        # contiguous vertical runs (an obstacle splits a lane)
        runs: list[tuple[int, int]] = []
        y0 = prev = ys[0]
        for y in ys[1:]:
            if y == prev + 1:
                prev = y
            else:
                runs.append((y0, prev))
                y0 = prev = y
        runs.append((y0, prev))
        if not upward:
            runs.reverse()
        for lo, hi in runs:
            a, b = ((x, lo), (x, hi)) if upward else ((x, hi), (x, lo))
            visit.append(a)
            if b != a:
                visit.append(b)
        upward = not upward
    cells: list[Cell] = [start]
    cur = start
    skipped = 0
    for wp in visit:
        res = astar.plan(grid, cur, wp, params)
        if res is None:
            skipped += 1
            continue
        cells.extend(res.cells[1:])
        cur = wp
    return CoverageResult(cells, visit, lanes, skipped)


def coverage_fraction(grid: OccupancyGrid, route: list[Cell],
                      params: PlanParams, lane_width: float) -> float:
    """Fraction of floor reachable from the route's start that lies
    within lane_width (Chebyshev) of some route cell."""
    if not route:
        return 0.0
    reach = _reachable(grid, route[0], params)
    if not reach:
        return 0.0
    r = max(1, round(lane_width / grid.cell_size))
    covered: set[Cell] = set()
    for (x, y) in route:
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                covered.add((x + dx, y + dy))
    hit = sum(1 for c in reach if c in covered)
    return hit / len(reach)
