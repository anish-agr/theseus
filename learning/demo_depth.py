"""Runnable, dependency-free proof of the monocular-depth lane.

Renders a synthetic room to depth images, runs the FULL production
pipeline (unproject -> gravity/floor fit -> height split -> temporal
persistence -> occupancy ingest) and writes a trace you open in the
exact same viewer as the planner demos:

    python learning/demo_depth.py
    python -m http.server 8123
    # -> http://localhost:8123/tools/viewer/index.html?trace=depth-trace.jsonl

This is the M0.5 acceptance artifact with zero ML dependencies: swap
scene.render_depth for a real depth network (run_depth.py) and the rest
is unchanged. Determinism makes it a golden fixture too.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine" / "src"))

from theseus_engine.grid import OccupancyGrid

from depth_projection import (Intrinsics, PersistenceFilter, depth_to_points,
                              fit_floor_height, split_by_height)
from pipeline import Frame, build_trace
from scene import render_depth, room_walls, walk_poses

SIZE = (4.0, 3.0)
CELL = 0.05
IMG_W, IMG_H = 56, 42


def build() -> tuple[OccupancyGrid, list[Frame], dict]:
    k = Intrinsics.from_fov(IMG_W, IMG_H, hfov_deg=68.0)
    walls = room_walls(SIZE, box=(1.6, 1.1, 0.8, 0.6))
    poses = walk_poses([(0.5, 0.5), (0.5, 2.4), (3.4, 2.4), (3.4, 0.6),
                        (1.0, 0.6)])
    grid = OccupancyGrid.from_meters(SIZE[0], SIZE[1], CELL)
    grid.clearance_cap = 1.2
    grid.auto_clearance = False
    frames: list[Frame] = []
    floor_zs: list[float] = []
    for pose in poses:
        depth = render_depth(pose, k, walls, IMG_W, IMG_H)
        pts = depth_to_points(depth, k, pose, stride=1, max_range=5.0)
        floor_z, _ = fit_floor_height(pts)
        floor_zs.append(floor_z)
        floor_pts, obstacle_pts, _high = split_by_height(pts, floor_z)
        frames.append(Frame((pose.pos[0], pose.pos[1]), pose.yaw,
                            floor_pts, obstacle_pts))
    stats = {
        "frames": len(frames),
        "floor_z_max_err": round(max(abs(z) for z in floor_zs), 4),
    }
    return grid, frames, stats


def run() -> tuple:
    grid, frames, stats = build()
    trace = build_trace(grid, frames, name="depth-mini", size_m=SIZE,
                        filt=PersistenceFilter(hits_needed=2, window=6))
    grid.refresh_clearance(force=True)
    free = sum(1 for y in range(grid.height) for x in range(grid.width)
               if grid.state((x, y)) == 1)
    occ = sum(1 for y in range(grid.height) for x in range(grid.width)
              if grid.state((x, y)) == 2)
    stats.update(free_cells=free, occ_cells=occ)
    return trace, grid, stats


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    trace, _grid, stats = run()
    trace.save(root / "tools" / "viewer" / "depth-trace.jsonl")
    trace.save(root / "fixtures" / "demo" / "depth-trace.jsonl")
    (root / "fixtures" / "golden" / "depth-mini.sha256").write_text(
        trace.sha256() + "\n", encoding="utf-8")
    print("depth-mini:", json.dumps(stats))
    print("view: /tools/viewer/index.html?trace=depth-trace.jsonl")


if __name__ == "__main__":
    main()
