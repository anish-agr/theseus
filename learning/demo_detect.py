"""Runnable, dependency-free proof of the detection-waypoint lane (B).

Real object detection needs YOLO + a phone (run_detect.py). To develop
and TEST the perception->waypoint chain with exact ground truth, this
synthesizes the detector's output: a camera walks a room where labeled
objects sit at known spots; each frame, objects in view are "detected"
(their base pixel, plus noise, plus the occasional false positive), then
the SAME production path recovers world positions —
project_pixel/pixel_ray_to_floor -> WaypointRegistry merge/promote/decay
— and we check the registry converges to the true objects and rejects
the noise.

    python learning/demo_detect.py

This is the M0.5 Lane-B acceptance artifact with zero ML dependencies:
swap the synthetic detector for YOLO and the recovery half is unchanged.
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine" / "src"))

from theseus_engine.geometry import dist
from theseus_engine.waypoints import WaypointRegistry

from depth_projection import (CameraPose, Intrinsics, pixel_ray_to_floor,
                              project_pixel)
from scene import walk_poses

IMG_W, IMG_H = 64, 48
OBJECTS = [
    ("fridge", (3.6, 2.6)),
    ("chair", (1.4, 1.0)),
    ("table", (2.4, 1.4)),
]


def run(seed: int = 0) -> tuple[WaypointRegistry, dict]:
    rng = random.Random(seed)
    k = Intrinsics.from_fov(IMG_W, IMG_H, hfov_deg=70.0)
    poses = walk_poses([(0.5, 0.5), (0.5, 2.4), (3.4, 2.4), (3.4, 0.6),
                        (1.0, 0.6)], height_m=1.4, pitch=0.5)
    reg = WaypointRegistry(merge_radius=0.6, promote_conf=2.0, drop_conf=0.3,
                           miss_decay=0.5)
    false_positives = 0
    for tick, pose in enumerate(poses, start=1):
        seen: set[str] = set()
        for label, world in OBJECTS:
            px = project_pixel((world[0], world[1], 0.0), k, pose)
            if px is None:
                continue
            u, v = px
            if not (0 <= u < IMG_W and 0 <= v < IMG_H):
                continue                          # out of frame
            if dist((pose.pos[0], pose.pos[1]), world) > 3.5:
                continue                          # detector range
            u += rng.uniform(-1.5, 1.5)           # detection jitter
            v += rng.uniform(-1.5, 1.5)
            hit = pixel_ray_to_floor(u, v, k, pose)
            if hit is None:
                continue
            wp = reg.report(label, hit, confidence=rng.uniform(0.6, 0.9),
                            tick=tick)
            seen.add(wp.uid)
        # a spurious detection now and then; a single low-confidence hit
        # must never reach the promote threshold (so it's never a target)
        if rng.random() < 0.15:
            false_positives += 1
            reg.report("ghost", (rng.uniform(0.5, 3.5), rng.uniform(0.5, 2.5)),
                       confidence=0.5, tick=tick)
        # Decay only what the camera actually imaged this frame: the floor
        # footprint the frame center hits, NOT a blind radius around the
        # camera (an object behind you is un-observed, not un-seen). This
        # is the frustum-vs-circle distinction the on-device provider will
        # make exactly; here we approximate the footprint by its center.
        footprint = pixel_ray_to_floor(k.cx, k.cy, k, pose)
        if footprint is not None:
            reg.observe_area(footprint, 1.3, tick=tick, seen_uids=seen)

    targets = reg.targets()
    stats = {
        "frames": len(poses),
        "false_positives_injected": false_positives,
        "targets": [(w.label, [round(w.pos[0], 2), round(w.pos[1], 2)],
                     round(w.confidence, 2)) for w in targets],
    }
    return reg, stats


def main() -> None:
    reg, stats = run()
    print("detect:", json.dumps(stats, indent=2))
    for label, (tx, ty) in OBJECTS:
        wp = reg.target_for(label)
        if wp:
            err = ((wp.pos[0] - tx) ** 2 + (wp.pos[1] - ty) ** 2) ** 0.5
            print(f"  {label:7} recovered at ({wp.pos[0]:.2f},{wp.pos[1]:.2f}) "
                  f"err={err:.2f}m conf={wp.confidence:.1f}")
        else:
            print(f"  {label:7} MISSED")


if __name__ == "__main__":
    main()
