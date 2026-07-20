"""Depth image -> world-model observations: the math under pseudo-LiDAR.

This is the risky half of Lane A (see README): a depth map is only useful
to the engine after it survives unprojection, gravity alignment, floor
removal, and height-band classification. All of that is deterministic
geometry — so it is implemented stdlib-only, unit-tested against
synthetic scenes, and will serve as the reference for the Swift/ARKit
version at M4 (where pose, intrinsics and gravity arrive for free).
The neural network that PRODUCES the depth map stays in run_depth_onnx.py
— models change, this math does not.

Conventions:
- image: u right, v down; camera space: X right, Y down, Z forward;
  `depth` is planar Z-depth (what depth networks emit), not ray length.
- world: z up, ground near z = 0; yaw CCW from +x (engine convention);
  pitch positive = camera tilted DOWN. Roll is assumed zero (phone held
  upright; ARKit gravity will supply the correction on-device).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from theseus_engine.geometry import Cell, Vec
from theseus_engine.grid import OccupancyGrid

XYZ = tuple[float, float, float]


@dataclass(frozen=True)
class Intrinsics:
    fx: float
    fy: float
    cx: float
    cy: float

    @classmethod
    def from_fov(cls, width: int, height: int, hfov_deg: float) -> "Intrinsics":
        f = (width / 2.0) / math.tan(math.radians(hfov_deg) / 2.0)
        return cls(f, f, width / 2.0, height / 2.0)


@dataclass(frozen=True)
class CameraPose:
    pos: XYZ            # (x, y, height) in world meters
    yaw: float          # radians, CCW from +x
    pitch: float        # radians, positive = looking down

    def axes(self) -> tuple[XYZ, XYZ, XYZ]:
        """(right, down, forward) unit vectors in world coordinates."""
        cy_, sy = math.cos(self.yaw), math.sin(self.yaw)
        cp, sp = math.cos(self.pitch), math.sin(self.pitch)
        forward = (cy_ * cp, sy * cp, -sp)
        right = (sy, -cy_, 0.0)
        down = (-sp * cy_, -sp * sy, -cp)   # = forward x right
        return right, down, forward


def unproject(u: float, v: float, depth: float, k: Intrinsics) -> XYZ:
    """Pixel + planar depth -> camera-space point."""
    return ((u - k.cx) * depth / k.fx, (v - k.cy) * depth / k.fy, depth)


def cam_to_world(p: XYZ, pose: CameraPose) -> XYZ:
    r, d, f = pose.axes()
    x, y, z = p
    return (pose.pos[0] + x * r[0] + y * d[0] + z * f[0],
            pose.pos[1] + x * r[1] + y * d[1] + z * f[1],
            pose.pos[2] + x * r[2] + y * d[2] + z * f[2])


def pixel_ray_to_floor(u: float, v: float, k: Intrinsics,
                       pose: CameraPose, floor_z: float = 0.0) -> Vec | None:
    """Where the ray through this pixel meets the floor plane (None if it
    points at or above the horizon). This is how detection boxes become
    world positions without any depth at all (Lane B)."""
    p1 = cam_to_world(unproject(u, v, 1.0, k), pose)
    dx = p1[0] - pose.pos[0]
    dy = p1[1] - pose.pos[1]
    dz = p1[2] - pose.pos[2]
    if dz >= -1e-9:
        return None
    t = (pose.pos[2] - floor_z) / -dz
    return (pose.pos[0] + t * dx, pose.pos[1] + t * dy)


def depth_to_points(depth: list[list[float]], k: Intrinsics, pose: CameraPose,
                    stride: int = 2, max_range: float = 4.0) -> list[XYZ]:
    """Unproject a (rows x cols) depth image into world points. Zero,
    negative and beyond-range depths are dropped (unknown, not free!)."""
    pts: list[XYZ] = []
    for v in range(0, len(depth), stride):
        row = depth[v]
        for u in range(0, len(row), stride):
            d = row[u]
            if d <= 0.0 or d > max_range:
                continue
            pts.append(cam_to_world(unproject(u, v, d, k), pose))
    return pts


def fit_floor_height(points: list[XYZ], bin_m: float = 0.05,
                     tol_m: float = 0.08, strong_frac: float = 0.3
                     ) -> tuple[float, int]:
    """Height of the floor plane among these points. Gravity is known
    (ARKit/IMU), so 'plane fitting' collapses to robust 1-D estimation
    along the vertical: histogram the z values and take the LOWEST bin
    that is strongly populated (>= strong_frac of the fullest bin),
    then refine as the mean of its inliers.

    Lowest-strong beats densest-overall on purpose: a camera facing a
    near wall sees more wall pixels than floor pixels, so the densest
    bin can land on the wall — but the floor is still the lowest surface
    with real support, and misplacing it upward would carve free space
    through the wall's base. Deterministic; no RANSAC lottery. Returns
    (floor_z, inlier_count); (0.0, 0) if there are no points."""
    if not points:
        return 0.0, 0
    bins: dict[int, int] = {}
    for _x, _y, z in points:
        b = round(z / bin_m)
        bins[b] = bins.get(b, 0) + 1
    threshold = strong_frac * max(bins.values())
    floor_b = min(b for b, count in bins.items() if count >= threshold)
    center = floor_b * bin_m
    inliers = [z for _x, _y, z in points if abs(z - center) <= tol_m]
    return (sum(inliers) / len(inliers), len(inliers)) if inliers else (center, 0)


def split_by_height(points: list[XYZ], floor_z: float,
                    band: tuple[float, float] = (0.15, 1.9)
                    ) -> tuple[list[XYZ], list[XYZ], list[XYZ]]:
    """(floor, obstacle, overhead) split. The band is what a walking
    human's body sweeps: below it is floor (walkable evidence), inside
    it blocks, above it is ceiling/lamps — ignored."""
    lo, hi = floor_z + band[0], floor_z + band[1]
    floor: list[XYZ] = []
    obstacle: list[XYZ] = []
    overhead: list[XYZ] = []
    for p in points:
        if p[2] < lo:
            floor.append(p)
        elif p[2] <= hi:
            obstacle.append(p)
        else:
            overhead.append(p)
    return floor, obstacle, overhead


class PersistenceFilter:
    """Cell-level temporal voting: an obstacle cell is only believed
    after `hits_needed` sightings within the last `window` ticks. Depth
    networks flicker at edges; a wall does not."""

    def __init__(self, hits_needed: int = 2, window: int = 6):
        self.hits_needed = hits_needed
        self.window = window
        self._hits: dict[Cell, list[int]] = {}

    def confirm(self, cells: list[Cell], tick: int) -> list[Cell]:
        out: list[Cell] = []
        for c in cells:
            ticks = [t for t in self._hits.get(c, []) if tick - t < self.window]
            ticks.append(tick)
            self._hits[c] = ticks
            if len(ticks) >= self.hits_needed:
                out.append(c)
        return out


def ingest(grid: OccupancyGrid, cam_xy: Vec, floor_pts: list[XYZ],
           obstacle_pts: list[XYZ], tick: int,
           filt: PersistenceFilter | None = None,
           carve: bool = True) -> list[Cell]:
    """Feed one classified depth frame into the world model through the
    production observe() path. Each cell is observed at most once per
    frame (N points in one frame are one observation, not N). Free-space
    carving marks the line of sight to each hit as free — same idea as the
    simulator's raycasts. Returns cells whose derived state changed."""
    changed: list[Cell] = []
    seen: set[Cell] = set()

    def observe(c: Cell, occupied: bool) -> None:
        if c in seen or not grid.in_bounds(c):
            return
        seen.add(c)
        if grid.observe(c, occupied, tick):
            changed.append(c)

    obstacle_cells = [grid.world_to_cell((p[0], p[1])) for p in obstacle_pts]
    if filt is not None:
        obstacle_cells = filt.confirm(obstacle_cells, tick)
    hit_cells = set(obstacle_cells)

    # Order encodes evidence priority within a frame: obstacle hits first
    # (they must never be shadowed by free evidence via the dedupe),
    # direct floor sightings second, line-of-sight carving last.
    for c in obstacle_cells:
        observe(c, True)
    for p in floor_pts:
        observe(grid.world_to_cell((p[0], p[1])), False)

    if carve:
        cs = grid.cell_size
        for target in ([(p[0], p[1]) for p in floor_pts]
                       + [(p[0], p[1]) for p in obstacle_pts]):
            length = math.hypot(target[0] - cam_xy[0], target[1] - cam_xy[1])
            steps = int(length / (cs * 0.7))
            for i in range(steps):
                t = i / max(1, steps)
                c = grid.world_to_cell((cam_xy[0] + (target[0] - cam_xy[0]) * t,
                                        cam_xy[1] + (target[1] - cam_xy[1]) * t))
                if c in hit_cells:
                    break               # do not carve through a hit
                observe(c, False)
    return changed
