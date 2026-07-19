"""Guidance ("Ariadne mode"): turn a planned path into egocentric cues.

The hero use case is a guided human, so the engine's real output is not a
polyline — it is a stream of instructions a person can act on without
seeing the map: "straight 3 m", "turn left 45°", "you're off the thread".
On-device these cues drive haptics (CoreHaptics), spatial audio (a PHASE
beacon placed at the lookahead point) and speech; here they are a typed
value that tests can assert on, which is exactly why the geometry
(especially turn SIGN: +angle = turn left, see geometry.py conventions)
is pinned down on Windows before any iPhone is involved.

Mechanics: pure-pursuit style. Project the pose onto the path, hold a
lookahead point a fixed arclength ahead, and report the bearing error to
it. Cross-track distance beyond `corridor_max` means the human has left
the corridor -> OFF_ROUTE, which the controller turns into a replan from
wherever they actually are.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .geometry import Vec, bearing, dist, point_along, project_point_segment, wrap_angle
from .grid import OccupancyGrid

STRAIGHT, TURN_LEFT, TURN_RIGHT, ARRIVE, OFF_ROUTE = (
    "straight", "turn_left", "turn_right", "arrive", "off_route")


@dataclass
class GuidanceCue:
    kind: str
    distance: float        # m: to next turn (straight), to path (off_route), to goal (arrive)
    angle_deg: float       # bearing error to lookahead point; + = turn left
    cross_track: float     # m off the path centerline
    corridor: float        # local corridor width (2 x clearance), m
    target: Vec            # lookahead point in world coords (steering aims here)


class GuidanceFollower:
    def __init__(self, path: list[Vec], lookahead: float = 0.9,
                 corridor_max: float = 0.9, arrive_radius: float = 0.45,
                 turn_thresh_deg: float = 22.0, vertex_turn_deg: float = 28.0):
        if len(path) < 1:
            raise ValueError("empty path")
        self.path = path
        self.lookahead = lookahead
        self.corridor_max = corridor_max
        self.arrive_radius = arrive_radius
        self.turn_thresh_deg = turn_thresh_deg
        self.vertex_turn_deg = vertex_turn_deg

    def _project(self, p: Vec) -> tuple[Vec, int, float, float]:
        """Nearest point on the path: (point, segment index, t, distance)."""
        if len(self.path) == 1:
            q = self.path[0]
            return q, 0, 0.0, dist(p, q)
        best = None
        for i in range(len(self.path) - 1):
            q, t = project_point_segment(p, self.path[i], self.path[i + 1])
            d = dist(p, q)
            if best is None or d < best[3]:
                best = (q, i, t, d)
        return best

    def _dist_to_next_turn(self, seg_i: int, t: float) -> float:
        """Arclength from the projection to the first vertex where the path
        bends by more than vertex_turn_deg (else to the goal)."""
        proj = point_along(self.path, seg_i, t, 0.0)
        acc = dist(proj, self.path[seg_i + 1]) if seg_i + 1 < len(self.path) else 0.0
        for j in range(seg_i + 1, len(self.path) - 1):
            d_in = bearing(self.path[j - 1] if j - 1 >= 0 else proj, self.path[j])
            d_out = bearing(self.path[j], self.path[j + 1])
            if abs(math.degrees(wrap_angle(d_out - d_in))) > self.vertex_turn_deg:
                return acc
            acc += dist(self.path[j], self.path[j + 1])
        return acc

    def cue(self, grid: OccupancyGrid, pose: tuple[float, float, float]) -> GuidanceCue:
        x, y, th = pose
        p = (x, y)
        goal = self.path[-1]
        if dist(p, goal) <= self.arrive_radius:
            return GuidanceCue(ARRIVE, dist(p, goal), 0.0, 0.0,
                               2.0 * grid.clearance(grid.world_to_cell(goal)), goal)
        proj, seg_i, t, cross = self._project(p)
        corridor = 2.0 * grid.clearance(grid.world_to_cell(proj))
        if cross > self.corridor_max:
            err = math.degrees(wrap_angle(bearing(p, proj) - th))
            return GuidanceCue(OFF_ROUTE, cross, err, cross, corridor, proj)
        look = point_along(self.path, seg_i, t, self.lookahead) if len(self.path) > 1 else goal
        err = math.degrees(wrap_angle(bearing(p, look) - th))
        if abs(err) < self.turn_thresh_deg:
            return GuidanceCue(STRAIGHT, self._dist_to_next_turn(seg_i, t),
                               err, cross, corridor, look)
        kind = TURN_LEFT if err > 0 else TURN_RIGHT
        return GuidanceCue(kind, dist(p, look), err, cross, corridor, look)
