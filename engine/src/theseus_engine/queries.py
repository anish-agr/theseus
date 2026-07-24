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
                     params: PlanParams,
                     approach_m: float = 0.75) -> PlanResult | None:
    """Optimal route to the closest object carrying this semantic label,
    or None. The route ends at an *approach point*: the nearest cell the
    BODY can legally occupy within approach_m (arm's reach) of the
    object. Strictly adjacent cells never qualify — one cell away from
    furniture is ~6 cm of clearance, and nobody's radius fits there;
    "at the fridge" means standing in front of it, not inside it."""
    labeled = [(i % grid.width, i // grid.width)
               for i, lab in grid.labels.items() if lab == label]
    if not labeled:
        return None
    r = max(1, int(approach_m / grid.cell_size))
    near: set = set()
    for (x, y) in labeled:
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy <= r * r:
                    near.add((x + dx, y + dy))
    goals = [c for c in near
             if grid.in_bounds(c) and grid.traversable(c, params)]
    if not goals:
        return None
    return FlowField.build(grid, sorted(goals), params).route_from(start)
