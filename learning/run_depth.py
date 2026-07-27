"""Lane A on REAL footage: monocular depth model -> occupancy trace.

    pip install -r learning/requirements.txt   # onnxruntime, opencv, numpy
    python learning/run_depth.py --video room.mp4 --model depth_anything_v2_vits.onnx

The neural network is the ONLY part that lives here; everything after the
depth map is the exact tested geometry in depth_projection.py, so what
you watch in the viewer is what the on-device DepthMLProvider will build.

POSE is the honest hard part offline. On-device, ARKit hands us camera
pose + intrinsics + gravity per frame for free. From a bare video we do
not have that, so this tool takes an optional --poses JSON (a list of
[x, y, height, yaw, pitch] per frame, e.g. exported from a rough logged
walk); without it, it pins a single static forward-looking pose and
builds the one occupancy slice in front of the camera. That slice is
still a real, viewable proof the model+projection work — full trajectory
mapping is what the phone unlocks at M1/M4.

SCALE: many monocular models emit RELATIVE (or inverse) depth. Pass
--depth-scale / --inverse-depth to convert to meters, or --metric if the
model already outputs meters (e.g. a *-metric checkpoint). The floor fit
then refines the vertical origin. When unsure, start with --metric and
sanity-check the wall distances in the viewer.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine" / "src"))

from theseus_engine.grid import OccupancyGrid

from depth_projection import (CameraPose, Intrinsics, PersistenceFilter,
                              depth_to_points, fit_floor_height, split_by_height)
from pipeline import Frame, build_trace


def _require(mod: str):
    try:
        return __import__(mod)
    except Exception:
        sys.exit(f"[run_depth] missing dependency '{mod}'. Install the lane:\n"
                 f"    pip install -r learning/requirements.txt")


def load_poses(path: str | None, n: int, args) -> list[CameraPose]:
    if path:
        raw = json.loads(Path(path).read_text())
        return [CameraPose((p[0], p[1], p[2]), p[3], p[4]) for p in raw]
    # static fallback: one fixed viewpoint for every frame
    return [CameraPose((args.x, args.y, args.height), args.yaw, args.pitch)] * n


def run(args) -> tuple:
    cv2 = _require("cv2")
    ort = _require("onnxruntime")
    np = _require("numpy")

    sess = ort.InferenceSession(args.model,
                                providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    # Dynamic-axis exports (e.g. onnx-community DA-V2) carry string dims,
    # not ints. 518 = 14*37 satisfies the ViT patch-size-multiple rule.
    shape = inp.shape if len(inp.shape) == 4 else (1, 3, 518, 518)
    in_h = shape[2] if isinstance(shape[2], int) else 518
    in_w = shape[3] if isinstance(shape[3], int) else 518
    # DA-V2 was trained on ImageNet-normalized input; raw /255 frames
    # produce visibly mushy depth.
    im_mean = np.array([0.485, 0.456, 0.406], dtype="float32")
    im_std = np.array([0.229, 0.224, 0.225], dtype="float32")

    cap = cv2.VideoCapture(args.video)
    depths, srcs, sizes = [], [], None
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if idx % args.stride == 0:
            sizes = (frame.shape[1], frame.shape[0])
            img = cv2.resize(frame, (int(in_w), int(in_h)))
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype("float32") / 255.0
            img = (img - im_mean) / im_std
            blob = img.transpose(2, 0, 1)[None]
            out = sess.run(None, {inp.name: blob})[0]
            depths.append(np.squeeze(out))
            srcs.append(idx)
        idx += 1
    cap.release()
    if not depths:
        sys.exit("[run_depth] no frames read from --video")

    w_px, h_px = sizes
    if args.intrinsics:
        fx, fy, cx, cy = (float(v) for v in args.intrinsics.split(","))
        k = Intrinsics(fx, fy, cx, cy)
    else:
        k = Intrinsics.from_fov(w_px, h_px, args.hfov)
    sparse = (json.loads(Path(args.sparse).read_text())
              if args.sparse else None)
    poses = load_poses(args.poses, len(depths), args)
    grid = OccupancyGrid.from_meters(args.map_w, args.map_h, args.cell,
                                     origin=(args.origin_x, args.origin_y))
    grid.clearance_cap = 1.2
    grid.auto_clearance = False
    filt = PersistenceFilter(hits_needed=2, window=6)

    frames = []
    for depth, pose, src in zip(depths, poses, srcs):
        d = np.asarray(depth, dtype="float32")
        d = cv2.resize(d, (w_px, h_px)) if d.shape != (h_px, w_px) else d
        if sparse is not None and src < len(sparse) and len(sparse[src]) >= 8:
            # Metric alignment: a relative-depth net's output r is affine
            # in INVERSE depth (scale AND shift are both free), so fit
            # 1/z = s*r + t against this frame's sparse ground-truth
            # samples and invert. At M4 on-device, ARKit's sparse feature
            # points play exactly this role — this is a rehearsal of the
            # production scale-recovery path, not a shortcut.
            samp = sparse[src]
            r = np.array([d[v, u] for u, v, _z in samp], dtype="float32")
            inv = np.array([1.0 / z for _u, _v, z in samp], dtype="float32")
            a_mat = np.stack([r, np.ones_like(r)], axis=1)
            (s, t), *_ = np.linalg.lstsq(a_mat, inv, rcond=None)
            inv_pred = s * d + t
            d = np.where(inv_pred > 1e-6, 1.0 / np.clip(inv_pred, 1e-6, None),
                         0.0).astype("float32")
        elif args.inverse_depth:
            d = 1.0 / np.clip(d, 1e-3, None)
        if not args.metric and sparse is None:
            d = d * args.depth_scale
        rows = d.tolist()
        pts = depth_to_points(rows, k, pose, stride=args.point_stride,
                              max_range=args.max_range)
        floor_z, _ = fit_floor_height(pts)
        floor_pts, obstacle_pts, _ = split_by_height(pts, floor_z)
        frames.append(Frame((pose.pos[0], pose.pos[1]), pose.yaw,
                            floor_pts, obstacle_pts))

    trace = build_trace(grid, frames, name="depth-live",
                        size_m=(args.map_w, args.map_h), filt=filt)
    return trace, grid


def main() -> None:
    ap = argparse.ArgumentParser(description="monocular depth -> occupancy trace")
    ap.add_argument("--video", required=True)
    ap.add_argument("--model", required=True, help="ONNX depth model")
    ap.add_argument("--poses", help="JSON [[x,y,height,yaw,pitch], ...] per frame")
    ap.add_argument("--sparse", help="JSON [[[u,v,z_m],...],...] per source "
                    "frame: ground-truth depth samples for metric alignment "
                    "(what ARKit feature points provide on-device)")
    ap.add_argument("--intrinsics", help="fx,fy,cx,cy (overrides --hfov)")
    ap.add_argument("--hfov", type=float, default=68.0)
    ap.add_argument("--stride", type=int, default=5, help="use every Nth frame")
    ap.add_argument("--point-stride", type=int, default=2)
    ap.add_argument("--max-range", type=float, default=4.0)
    ap.add_argument("--metric", action="store_true", help="model outputs meters")
    ap.add_argument("--inverse-depth", action="store_true")
    ap.add_argument("--depth-scale", type=float, default=1.0)
    ap.add_argument("--map-w", type=float, default=8.0)
    ap.add_argument("--map-h", type=float, default=8.0)
    ap.add_argument("--cell", type=float, default=0.05)
    ap.add_argument("--origin-x", type=float, default=0.0)
    ap.add_argument("--origin-y", type=float, default=0.0)
    # static fallback pose (when --poses is absent)
    ap.add_argument("--x", type=float, default=4.0)
    ap.add_argument("--y", type=float, default=0.5)
    ap.add_argument("--height", type=float, default=1.4)
    ap.add_argument("--yaw", type=float, default=1.5708)
    ap.add_argument("--pitch", type=float, default=0.5)
    ap.add_argument("--out", default="tools/viewer/depth-live-trace.jsonl")
    args = ap.parse_args()

    trace, _grid = run(args)
    out = Path(args.out)
    trace.save(out)
    print(f"[run_depth] wrote {out} ({len(trace.lines) - 1} frames)")
    print("view: /tools/viewer/index.html?trace=" + out.name)


if __name__ == "__main__":
    main()
