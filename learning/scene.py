"""A tiny analytic depth renderer for offline testing without a camera.

Real footage needs an ONNX depth model and a phone (run_depth.py). To
develop and TEST the projection/ingestion math with exact ground truth,
this renders a planar Z-depth image of a synthetic room — a floor at z=0
plus finite vertical wall segments — by ray-plane/ray-quad intersection.

The depth value written per pixel is the ray parameter t of the nearest
hit, which (because the ray direction is p1 - camera for p1 unprojected
at depth 1) equals planar Z-depth exactly — so depth_projection.py can
unproject it back with the identical intrinsics and recover the scene.
This renderer is the stand-in for reality; it is deliberately NOT used by
the engine.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from depth_projection import CameraPose, Intrinsics, cam_to_world, unproject


@dataclass(frozen=True)
class Wall:
    a: tuple[float, float]     # endpoint (x, y)
    b: tuple[float, float]
    height: float = 2.2
    label: str = "wall"


def _ray_wall_t(pos, d, w: Wall) -> float | None:
    ax, ay = w.a
    ex, ey = w.b[0] - ax, w.b[1] - ay
    det = -d[0] * ey + ex * d[1]
    if abs(det) < 1e-12:
        return None
    rx, ry = ax - pos[0], ay - pos[1]
    t = (rx * -ey + ex * ry) / det
    s = (d[0] * ry - d[1] * rx) / det
    if t <= 1e-6 or not (0.0 <= s <= 1.0):
        return None
    z = pos[2] + t * d[2]
    if 0.0 <= z <= w.height:
        return t
    return None


def render_depth(pose: CameraPose, k: Intrinsics, walls: list[Wall],
                 width: int, height: int, floor_z: float = 0.0,
                 max_range: float = 6.0) -> list[list[float]]:
    """Planar Z-depth image of floor + walls (0.0 where nothing is hit)."""
    img = [[0.0] * width for _ in range(height)]
    for v in range(height):
        row = img[v]
        for u in range(width):
            p1 = cam_to_world(unproject(u, v, 1.0, k), pose)
            d = (p1[0] - pose.pos[0], p1[1] - pose.pos[1], p1[2] - pose.pos[2])
            best = None
            if d[2] < -1e-9:                      # floor plane
                tf = (pose.pos[2] - floor_z) / -d[2]
                if tf > 1e-6:
                    best = tf
            for w in walls:
                tw = _ray_wall_t(pose.pos, d, w)
                if tw is not None and (best is None or tw < best):
                    best = tw
            if best is not None and best <= max_range:
                row[u] = best
    return img


def room_walls(size_m=(4.0, 3.0), box=(1.6, 1.1, 0.8, 0.6)) -> list[Wall]:
    """Four perimeter walls plus a rectangular obstacle (x, y, w, h)."""
    w, h = size_m
    bx, by, bw, bh = box
    return [
        Wall((0.0, 0.0), (w, 0.0)), Wall((w, 0.0), (w, h)),
        Wall((w, h), (0.0, h)), Wall((0.0, h), (0.0, 0.0)),
        Wall((bx, by), (bx + bw, by), height=0.8, label="box"),
        Wall((bx + bw, by), (bx + bw, by + bh), height=0.8, label="box"),
        Wall((bx + bw, by + bh), (bx, by + bh), height=0.8, label="box"),
        Wall((bx, by + bh), (bx, by), height=0.8, label="box"),
    ]


def walk_poses(waypoints, height_m=1.4, pitch=0.55, step_m=0.18):
    """Camera poses walking through waypoints, yaw following travel
    direction (like a person sweeping a phone forward while moving)."""
    poses = []
    for i in range(len(waypoints) - 1):
        ax, ay = waypoints[i]
        bx, by = waypoints[i + 1]
        seg = math.hypot(bx - ax, by - ay)
        yaw = math.atan2(by - ay, bx - ax)
        n = max(1, int(seg / step_m))
        for k in range(n):
            t = k / n
            poses.append(CameraPose((ax + (bx - ax) * t, ay + (by - ay) * t,
                                     height_m), yaw, pitch))
    poses.append(CameraPose((waypoints[-1][0], waypoints[-1][1], height_m),
                            poses[-1].yaw if poses else 0.0, pitch))
    return poses
