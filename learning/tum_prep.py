"""Prepare a TUM RGB-D sequence for run_depth / run_detect.

    python learning/tum_prep.py --dir footage/rgbd_dataset_freiburg1_desk

Why TUM: it is real handheld footage of a real cluttered room WITH
motion-capture ground truth for the camera pose of every frame — the
one thing a plain phone video lacks and exactly what ARKit hands us for
free on-device. With it we can rehearse FULL-TRAJECTORY mapping offline
instead of the single-slice static-pose fallback.

Outputs (next to --dir):
  <name>.avi          the RGB frames as a video (every --stride-th frame)
  <name>-poses.json   [[x, y, height, yaw, pitch], ...] one per video frame
  <name>-sparse.json  [[[u, v, z_m], ...], ...] ground-truth depth samples
                      per video frame — run_depth uses these to fit the
                      monocular model's relative depth to meters, the same
                      alignment ARKit's sparse feature points will provide
                      on-device at M4.

Convention mapping (see depth_projection.py):
- TUM ground truth is camera->world (x right, y down, z forward optical
  frame; mocap world is gravity-aligned, z up — asserted, not assumed).
- Our CameraPose has yaw (CCW from +x) and pitch (positive = down) but NO
  ROLL — a phone is held roughly upright and ARKit's gravity supplies the
  correction on-device. Handheld TUM footage does roll, so we report the
  residual; frames with |roll| > --max-roll-deg are dropped rather than
  ingested wrongly tilted.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

# TUM freiburg1 color-camera intrinsics (from the dataset docs)
FR1_INTRINSICS = "517.3,516.5,318.6,255.3"
DEPTH_FACTOR = 5000.0          # png value / 5000 = meters


def read_list(path: Path) -> list[tuple[float, list[str]]]:
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        out.append((float(parts[0]), parts[1:]))
    return out


def associate(a: list, b: list, tol: float = 0.02) -> list[tuple]:
    """Nearest-timestamp matching (two-pointer over sorted lists)."""
    out, j = [], 0
    for ta, va in a:
        while j + 1 < len(b) and abs(b[j + 1][0] - ta) <= abs(b[j][0] - ta):
            j += 1
        if abs(b[j][0] - ta) <= tol:
            out.append((ta, va, b[j][1]))
    return out


def quat_to_cols(qx, qy, qz, qw):
    """Rotation-matrix columns (right, down, forward) of the optical frame
    expressed in world coordinates."""
    right = (1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy + qz * qw),
             2 * (qx * qz - qy * qw))
    down = (2 * (qx * qy - qz * qw), 1 - 2 * (qx * qx + qz * qz),
            2 * (qy * qz + qx * qw))
    fwd = (2 * (qx * qz + qy * qw), 2 * (qy * qz - qx * qw),
           1 - 2 * (qx * qx + qy * qy))
    return right, down, fwd


def main() -> None:
    ap = argparse.ArgumentParser(description="TUM RGB-D -> theseus inputs")
    ap.add_argument("--dir", required=True, help="extracted dataset folder")
    ap.add_argument("--stride", type=int, default=4, help="every Nth frame")
    ap.add_argument("--sparse-n", type=int, default=300,
                    help="ground-truth depth samples per frame")
    ap.add_argument("--max-depth", type=float, default=5.0)
    ap.add_argument("--max-roll-deg", type=float, default=15.0)
    args = ap.parse_args()

    try:
        import cv2
        import numpy as np
    except Exception:
        sys.exit("[tum_prep] needs opencv + numpy: "
                 "pip install -r learning/requirements.txt")

    root = Path(args.dir)
    name = root.name.replace("rgbd_dataset_", "tum_")
    rgb = read_list(root / "rgb.txt")
    dep = read_list(root / "depth.txt")
    gt = read_list(root / "groundtruth.txt")

    pairs = associate(rgb, dep)                    # (t, rgb_file, dep_file)
    trip = associate([(t, (vr[0], vd[0])) for t, vr, vd in pairs], gt)
    if not trip:
        sys.exit("[tum_prep] association produced no frames")

    # --- verify the mocap world really is z-up (assert, don't assume) ----
    downs = []
    for _, _, pose in trip[:: max(1, len(trip) // 50)]:
        _, d, _ = quat_to_cols(*(float(x) for x in pose[3:7]))
        downs.append(d)
    mean_down_z = sum(d[2] for d in downs) / len(downs)
    if mean_down_z > -0.7:
        sys.exit(f"[tum_prep] world does not look z-up "
                 f"(mean camera-down z = {mean_down_z:.2f}); refusing")

    frames, poses, sparse, rolls, dropped = [], [], [], [], 0
    for i, (_, (rgb_rel, dep_rel), pose) in enumerate(trip):
        if i % args.stride:
            continue
        tx, ty, tz, qx, qy, qz, qw = (float(x) for x in pose[:7])
        right, down, fwd = quat_to_cols(qx, qy, qz, qw)
        yaw = math.atan2(fwd[1], fwd[0])
        pitch = -math.asin(max(-1.0, min(1.0, fwd[2])))
        # roll residual: how far the actual right axis is from the
        # no-roll right axis, measured around the forward axis
        exp_right = (math.sin(yaw), -math.cos(yaw), 0.0)
        exp_down = (-math.sin(pitch) * math.cos(yaw),
                    -math.sin(pitch) * math.sin(yaw), -math.cos(pitch))
        roll = math.atan2(sum(a * b for a, b in zip(right, exp_down)),
                          sum(a * b for a, b in zip(right, exp_right)))
        rolls.append(abs(roll))
        if abs(roll) > math.radians(args.max_roll_deg):
            dropped += 1
            continue

        img = cv2.imread(str(root / rgb_rel))
        dpt = cv2.imread(str(root / dep_rel), cv2.IMREAD_UNCHANGED)
        if img is None or dpt is None:
            continue
        z = dpt.astype("float32") / DEPTH_FACTOR
        ok = (z > 0.1) & (z < args.max_depth)
        vs, us = np.nonzero(ok)
        if len(us) < 50:
            continue
        pick = np.random.default_rng(i).choice(len(us),
                                               min(args.sparse_n, len(us)),
                                               replace=False)
        samples = [[int(us[p]), int(vs[p]), round(float(z[vs[p], us[p]]), 4)]
                   for p in pick]
        frames.append(img)
        poses.append([round(tx, 4), round(ty, 4), round(tz, 4),
                      round(yaw, 5), round(pitch, 5)])
        sparse.append(samples)

    if not frames:
        sys.exit("[tum_prep] no usable frames after roll filtering")

    h, w = frames[0].shape[:2]
    vid_path = root.parent / f"{name}.avi"
    out = cv2.VideoWriter(str(vid_path), cv2.VideoWriter_fourcc(*"MJPG"),
                          30 / args.stride, (w, h))
    for f in frames:
        out.write(f)
    out.release()
    (root.parent / f"{name}-poses.json").write_text(json.dumps(poses))
    (root.parent / f"{name}-sparse.json").write_text(json.dumps(sparse))

    xs = [p[0] for p in poses]
    ys = [p[1] for p in poses]
    mean_roll = math.degrees(sum(rolls) / len(rolls))
    print(f"[tum_prep] {len(frames)} frames -> {vid_path.name} "
          f"({dropped} dropped for roll; mean |roll| {mean_roll:.1f} deg)")
    print(f"[tum_prep] camera track x [{min(xs):.2f},{max(xs):.2f}] "
          f"y [{min(ys):.2f},{max(ys):.2f}] height "
          f"~{sum(p[2] for p in poses) / len(poses):.2f}")
    ox, oy = min(xs) - 3.5, min(ys) - 3.5
    mw = (max(xs) - min(xs)) + 7.0
    mh = (max(ys) - min(ys)) + 7.0
    print("[tum_prep] suggested run:")
    print(f"  python learning/run_depth.py --video footage/{vid_path.name} "
          f"--model learning/models/depth_anything_v2_small.onnx "
          f"--poses footage/{name}-poses.json "
          f"--sparse footage/{name}-sparse.json "
          f"--intrinsics {FR1_INTRINSICS} --stride 1 "
          f"--map-w {mw:.1f} --map-h {mh:.1f} "
          f"--origin-x {ox:.1f} --origin-y {oy:.1f}")


if __name__ == "__main__":
    main()
