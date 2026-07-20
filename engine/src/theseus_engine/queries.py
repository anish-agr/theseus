"""Spatial utility queries — small solvers over the shared world model.

The payoff of the "one world model, many solvers" rule is that features
like these cost ~20 lines each, because the grid already maintains
clearance, semantics and costs:

- corridor_profile / fits_through — "will this couch fit through there?"
  v0 is disk-swept: a route admits width w iff every point along it has
  clearance >= w/2. (An oriented-rectangle sweep is the M6 refinement;
  the disk model is conservative for long objects cornering and slightly
  permissive for diagonal shimmies — honest enough to flag pinch points.)
- nearest_semantic — "take me to the closest <label>": a flow field whose
  goals are every traversable cell ADJACENT to a matching labeled cell
  (you stand next to the fridge, not inside it).
"""

from __future__ import annotations

from .astar import PlanResult
from .flowfield import FlowField
from .geometry import INF, Vec, dist, point_along
from .grid import OccupancyGrid, PlanParams


def corridor_profile(grid: OccupancyGrid, pts: list[Vec],
                     sample_m: float = 0.15) -> list[tuple[float, float]]:
    """(arc_length, corridor_width) samples along a world-space polyline.
    Corridor width at a point is twice the clearance field there."""
    if len(pts) < 2:
        c = grid.world_to_cell(pts[0]) if pts else (0, 0)
        return [(0.0, 2.0 * grid.clearance(c))]
    out: list[tuple[float, float]] = []
    s = 0.0
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        seg = dist(a, b)
        steps = max(1, int(seg / sample_m))
        last = steps + 1 if i == len(pts) - 2 else steps  # include endpoint once
        for k in range(last):
            t = k / steps
            p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            width = 2.0 * grid.clearance(grid.world_to_cell(p))
            out.append((s + seg * t, width))
        s += seg
    return out


def fits_through(grid: OccupancyGrid, pts: list[Vec], width_m: float,
                 margin_m: float = 0.05) -> tuple[bool, Vec | None, float]:
    """Can an object of the given width ride this route?
    Returns (verdict, pinch_point_or_None, narrowest_width)."""
    need = width_m + 2.0 * margin_m
    worst_s, worst_w = 0.0, INF
    for s, w in corridor_profile(grid, pts):
        if w < worst_w:
            worst_s, worst_w = s, w
    if worst_w >= need:
        return True, None, worst_w
    pinch = point_along(pts, 0, 0.0, worst_s) if len(pts) >= 2 else pts[0]
    return False, pinch, worst_w


def nearest_semantic(grid: OccupancyGrid, start, label: str,
                     params: PlanParams) -> PlanResult | None:
    """Optimal route to the closest object carrying this semantic label
    (ends on a traversable cell adjacent to it), or None."""
    goals = []
    for i, lab in grid.labels.items():
        if lab != label:
            continue
        c = (i % grid.width, i // grid.width)
        for v, _step in grid.neighbors8(c):
            if grid.traversable(v, params):
                goals.append(v)
    if not goals:
        return None
    return FlowField.build(grid, goals, params).route_from(start)
