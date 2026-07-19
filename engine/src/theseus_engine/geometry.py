"""Geometry primitives.

Plain tuples and floats only (no numpy): the engine is the reference
implementation for a later line-by-line Swift port, so it sticks to
constructs that translate 1:1.

Conventions (canonical for the whole project):
- world units are meters; top-down view, +x right, +y up
- headings in radians, 0 along +x, counter-clockwise positive
- a positive bearing error means "turn left"
- grid cells are (col, row) integer tuples; cell (0, 0) has its corner at
  the grid origin and its center at origin + cell_size/2
"""

from __future__ import annotations

import math

Vec = tuple[float, float]
Cell = tuple[int, int]

SQRT2 = math.sqrt(2.0)
INF = float("inf")


def dist(a: Vec, b: Vec) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def wrap_angle(a: float) -> float:
    """Wrap any angle to (-pi, pi]."""
    return math.atan2(math.sin(a), math.cos(a))


def bearing(frm: Vec, to: Vec) -> float:
    """Absolute heading of the vector frm -> to."""
    return math.atan2(to[1] - frm[1], to[0] - frm[0])


def octile(a: Cell, b: Cell) -> float:
    """Octile distance in cell units: exact shortest 8-connected distance
    on an empty grid, and an admissible/consistent A* heuristic under a
    cost model whose cheapest cell cost is 1.0."""
    dx = abs(a[0] - b[0])
    dy = abs(a[1] - b[1])
    lo, hi = (dx, dy) if dx < dy else (dy, dx)
    return (hi - lo) + SQRT2 * lo


def project_point_segment(p: Vec, a: Vec, b: Vec) -> tuple[Vec, float]:
    """Closest point on segment a-b to p, plus the parameter t in [0, 1]."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy
    if length_sq <= 1e-12:
        return a, 0.0
    t = ((p[0] - ax) * dx + (p[1] - ay) * dy) / length_sq
    t = max(0.0, min(1.0, t))
    return (ax + t * dx, ay + t * dy), t


def polyline_length(pts: list[Vec]) -> float:
    return sum(dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def point_along(pts: list[Vec], start_i: int, start_t: float, ahead: float) -> Vec:
    """Walk `ahead` meters along a polyline starting from parameter
    (segment start_i, fraction start_t); clamps at the final point."""
    if not pts:
        raise ValueError("empty polyline")
    if len(pts) == 1:
        return pts[0]
    a, b = pts[start_i], pts[start_i + 1]
    pos = (a[0] + (b[0] - a[0]) * start_t, a[1] + (b[1] - a[1]) * start_t)
    remaining = ahead
    i = start_i
    while True:
        seg_end = pts[i + 1]
        d = dist(pos, seg_end)
        if remaining <= d or i == len(pts) - 2:
            if d <= 1e-9:
                return seg_end
            f = min(1.0, remaining / d)
            return (pos[0] + (seg_end[0] - pos[0]) * f,
                    pos[1] + (seg_end[1] - pos[1]) * f)
        remaining -= d
        pos = seg_end
        i += 1
