"""Headless simulator: ground-truth world, mock sensor, simple kinematics.

This stands in for ARKit until milestone M1. The correspondence is:

  simulator                      on-device reality
  -----------------------------  ---------------------------------------
  truth grid + movers            the physical room and the people in it
  sense() FOV raycasts           depth/mesh/plane observations projected
                                 into the world grid (perception layer)
  est grid                       the shared world model (same OccupancyGrid)
  step_motion()                  the human walking / the virtual agent

Everything downstream of `est` — planners, steering, guidance, FSM — is
production logic exercised unmodified. That is the entire point: the
simulator is disposable, the engine is not.

The sensor deliberately has a limited FOV and range, so maps are built
incrementally, unknown space is a first-class condition, and a mover that
walked through a scanned corridor leaves stale "occupied" cells behind
until re-observed — the exact situation D* Lite exists for.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .geometry import Cell, Vec, dist, wrap_angle
from .grid import OCCUPIED, OccupancyGrid, PlanParams


@dataclass
class Mover:
    """An obstacle ping-ponging along a polyline (a person, a pet, a
    roomba). Deterministic — golden traces depend on it."""
    pts: list[Vec]
    speed: float = 0.5
    radius: float = 0.25
    label: str = "person"
    _s: float = field(default=0.0, repr=False)
    _dir: float = field(default=1.0, repr=False)

    def _length(self) -> float:
        return sum(dist(self.pts[i], self.pts[i + 1])
                   for i in range(len(self.pts) - 1))

    def advance(self, dt: float, avoid: Vec | None = None,
                keepout: float = 0.0) -> None:
        """Advance along the polyline; if `avoid` is given, refuse steps
        that close within `keepout` of it — people do not walk through
        each other, they pause."""
        total = self._length()
        if total <= 1e-9:
            return
        old_s, old_dir, old_pos = self._s, self._dir, self.pos
        self._s += self._dir * self.speed * dt
        while self._s < 0.0 or self._s > total:
            if self._s < 0.0:
                self._s = -self._s
                self._dir = 1.0
            else:
                self._s = 2.0 * total - self._s
                self._dir = -1.0
        if avoid is not None:
            new_pos = self.pos
            if (dist(new_pos, avoid) < keepout
                    and dist(new_pos, avoid) < dist(old_pos, avoid)):
                self._s, self._dir = old_s, old_dir

    @property
    def pos(self) -> Vec:
        remaining = self._s
        for i in range(len(self.pts) - 1):
            a, b = self.pts[i], self.pts[i + 1]
            d = dist(a, b)
            if remaining <= d or i == len(self.pts) - 2:
                if d <= 1e-9:
                    return a
                f = min(1.0, remaining / d)
                return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)
            remaining -= d
        return self.pts[-1]


class Simulator:
    def __init__(self, room: dict, params: PlanParams, dt: float = 0.1,
                 sensor_range: float = 3.0, sensor_fov_deg: float = 100.0,
                 ray_step_deg: float = 2.5, max_turn_rate: float = 3.0):
        self.room = room
        self.params = params
        self.dt = dt
        self.sensor_range = sensor_range
        self.sensor_fov = math.radians(sensor_fov_deg)
        self.ray_step = math.radians(ray_step_deg)
        self.max_turn_rate = max_turn_rate
        self.tick = 0

        cell = room["cell"]
        w_m, h_m = room["size_m"]
        self.truth = OccupancyGrid.from_meters(w_m, h_m, cell)
        self.truth.lo = [-4.0] * (self.truth.width * self.truth.height)  # all FREE
        for r in room.get("rects", []):
            self._rasterize_rect(r)
        self.truth.refresh_clearance(force=True)

        self.est = OccupancyGrid.from_meters(w_m, h_m, cell)
        self.est.clearance_cap = 1.2   # nothing consumes clearance beyond this
        self.est.auto_clearance = False

        sx, sy = room["start"]
        self.pose: tuple[float, float, float] = (sx, sy, room.get("start_heading", 0.0))
        self.movers = [Mover(pts=[tuple(p) for p in m["pts"]],
                             speed=m.get("speed", 0.5),
                             radius=m.get("radius", 0.25),
                             label=m.get("label", "person"))
                       for m in room.get("movers", [])]
        self.collisions = 0

    def _rasterize_rect(self, r: dict) -> None:
        cs = self.truth.cell_size
        x0 = int(r["x"] / cs)
        y0 = int(r["y"] / cs)
        x1 = int(math.ceil((r["x"] + r["w"]) / cs))
        y1 = int(math.ceil((r["y"] + r["h"]) / cs))
        for cy in range(y0, y1):
            for cx in range(x0, x1):
                self.truth.set_state((cx, cy), OCCUPIED, r.get("label", ""))

    # ---- ground truth queries -------------------------------------------

    def truth_blocked(self, c: Cell) -> tuple[bool, str]:
        if self.truth.state(c) == OCCUPIED:
            return True, self.truth.label(c)
        center = self.truth.cell_center(c)
        for m in self.movers:
            if dist(center, m.pos) <= m.radius + self.truth.cell_size * 0.5:
                return True, m.label
        return False, ""

    # ---- per-tick interface ----------------------------------------------

    def advance(self) -> None:
        self.tick += 1
        agent = (self.pose[0], self.pose[1])
        for m in self.movers:
            m.advance(self.dt, avoid=agent,
                      keepout=m.radius + self.params.radius + 0.05)

    def sense(self) -> list[Cell]:
        """Cast FOV rays from the pose into ground truth and update the
        estimated grid. Returns cells whose derived state changed —
        exactly what D* Lite wants to hear about."""
        x, y, th = self.pose
        changed: list[Cell] = []
        cs = self.est.cell_size
        # proprioception: the space my own body occupies is free
        span = int(self.params.radius / cs) + 1
        me = self.est.world_to_cell((x, y))
        for dy in range(-span, span + 1):
            for dx in range(-span, span + 1):
                c = (me[0] + dx, me[1] + dy)
                if self.est.in_bounds(c) and \
                        dist(self.est.cell_center(c), (x, y)) <= self.params.radius:
                    if self.est.observe(c, False, self.tick):
                        changed.append(c)
        # FOV raycasts
        n_rays = max(3, int(self.sensor_fov / self.ray_step) + 1)
        march = cs * 0.9
        for k in range(n_rays):
            ang = th - self.sensor_fov / 2.0 + k * self.sensor_fov / (n_rays - 1)
            ca, sa = math.cos(ang), math.sin(ang)
            d = cs * 0.8
            last: Cell | None = None
            while d <= self.sensor_range:
                c = self.est.world_to_cell((x + ca * d, y + sa * d))
                if not self.est.in_bounds(c):
                    break
                if c != last:
                    blocked, label = self.truth_blocked(c)
                    if self.est.observe(c, blocked, self.tick, label):
                        changed.append(c)
                    if blocked:
                        break
                    last = c
                d += march
        return changed

    def step_motion(self, heading_cmd: float, speed_cmd: float) -> bool:
        """Turn-rate-limited kinematics with body collision checking
        against ground truth. Returns True on a (prevented) collision."""
        x, y, th = self.pose
        dth = wrap_angle(heading_cmd - th)
        max_dth = self.max_turn_rate * self.dt
        th = wrap_angle(th + max(-max_dth, min(max_dth, dth)))
        collided = False
        if speed_cmd > 1e-6:
            nx = x + math.cos(th) * speed_cmd * self.dt
            ny = y + math.sin(th) * speed_cmd * self.dt
            r = self.params.radius * 0.8
            ok = True
            for i in range(9):
                if i == 0:
                    px, py = nx, ny
                else:
                    a = (i - 1) * math.pi / 4.0
                    px, py = nx + math.cos(a) * r, ny + math.sin(a) * r
                if self.truth_blocked(self.truth.world_to_cell((px, py)))[0]:
                    ok = False
                    break
            if ok:
                x, y = nx, ny
            else:
                collided = True
                self.collisions += 1
        self.pose = (x, y, th)
        return collided

    def mover_positions(self) -> list[list[float]]:
        return [[m.pos[0], m.pos[1], m.radius] for m in self.movers]
