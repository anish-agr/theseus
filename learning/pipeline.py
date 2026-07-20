"""Bridge: a stream of classified depth/detection frames -> a viewer trace.

Whatever the source of per-frame geometry — the synthetic renderer in
demo_depth.py, a real ONNX depth model in run_depth.py, or an ARKit
DepthMLProvider on-device — it ends here: frames are ingested into a
theseus_engine.OccupancyGrid through the SAME production path the
simulator uses, and emitted as the SAME JSONL the golden traces and the
HTML viewer speak. So the depth lane is watchable in tools/viewer with
zero new tooling, and "does my perception produce a sane map?" is
answered by eyeball the same way the planner is.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from theseus_engine.geometry import Vec
from theseus_engine.grid import OccupancyGrid
from theseus_engine.trace import TraceWriter

from depth_projection import PersistenceFilter, ingest


@dataclass
class Frame:
    """One processed observation: where the camera was, and the world
    points its depth map produced, already split by height."""
    cam_xy: Vec
    heading: float
    floor_pts: list
    obstacle_pts: list
    detections: list = field(default_factory=list)  # (label, world_xy, conf)


def build_trace(grid: OccupancyGrid, frames: list[Frame], *, name: str,
                size_m, dt: float = 0.1, radius: float = 0.28,
                clearance_every: int = 5,
                filt: PersistenceFilter | None = None) -> TraceWriter:
    """Replay frames into `grid`, emitting one trace frame each. The
    header mirrors demo.py so the viewer renders it identically."""
    trace = TraceWriter({
        "name": name,
        "cell": grid.cell_size,
        "w": grid.width,
        "h": grid.height,
        "size_m": list(size_m),
        "dt": dt,
        "radius": radius,
        "sensor": {"source": "depth-ml"},
        "waypoints": {},
        "furniture": [],
        "scan_pts": [],
    })
    for i, fr in enumerate(frames, start=1):
        changed = ingest(grid, fr.cam_xy, fr.floor_pts, fr.obstacle_pts,
                         tick=i, filt=filt)
        if i % clearance_every == 0:
            grid.refresh_clearance()
        frame = {
            "t": round(i * dt, 3),
            "pose": [fr.cam_xy[0], fr.cam_xy[1], fr.heading],
            "state": "MAPPING",
            "occ": [[c[0], c[1], grid.state(c)] for c in changed],
            "movers": [],
        }
        if fr.detections:
            frame["detections"] = [[d[0], d[1][0], d[1][1], round(d[2], 3)]
                                   for d in fr.detections]
        trace.frame(**frame)
    return trace
