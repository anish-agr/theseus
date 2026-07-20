"""Lane B on REAL footage: object detection -> named waypoints.

    pip install -r learning/requirements.txt   # ultralytics (+ opencv)
    python learning/run_detect.py --video room.mp4 --poses walk.json

For each frame, YOLO gives boxes; the box's floor-contact pixel
(bottom-center) is ray-cast onto the floor plane via the SAME tested
geometry (pixel_ray_to_floor), and the SAME WaypointRegistry
merges/promotes/decays hits into stable named targets — exactly what
demo_detect.py proves against synthetic ground truth. Swapping the
synthetic detector for YOLO is the only change; the recovery half is
identical and already tested.

Pose caveat is the same as run_depth.py: on-device ARKit supplies
per-frame pose/intrinsics; offline you pass --poses or accept a static
pose. Waypoint world accuracy is only as good as that pose.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine" / "src"))

from theseus_engine.waypoints import WaypointRegistry

from depth_projection import CameraPose, Intrinsics, pixel_ray_to_floor

# COCO classes that make sense as indoor navigation waypoints
DEFAULT_CLASSES = {"refrigerator": "fridge", "chair": "chair",
                   "couch": "couch", "bed": "bed", "toilet": "toilet",
                   "sink": "sink", "dining table": "table", "tv": "tv",
                   "oven": "oven", "microwave": "microwave"}


def _require(mod: str):
    try:
        return __import__(mod)
    except Exception:
        sys.exit(f"[run_detect] missing dependency '{mod}'. Install the lane:\n"
                 f"    pip install -r learning/requirements.txt")


def load_poses(path: str | None, n: int, args) -> list[CameraPose]:
    if path:
        raw = json.loads(Path(path).read_text())
        return [CameraPose((p[0], p[1], p[2]), p[3], p[4]) for p in raw]
    return [CameraPose((args.x, args.y, args.height), args.yaw, args.pitch)] * n


def run(args) -> WaypointRegistry:
    _require("cv2")
    ultra = _require("ultralytics")
    model = ultra.YOLO(args.model)

    import cv2
    cap = cv2.VideoCapture(args.video)
    frames = []
    sizes = None
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if idx % args.stride == 0:
            sizes = (frame.shape[1], frame.shape[0])
            frames.append(frame)
        idx += 1
    cap.release()
    if not frames:
        sys.exit("[run_detect] no frames read from --video")

    w_px, h_px = sizes
    k = Intrinsics.from_fov(w_px, h_px, args.hfov)
    poses = load_poses(args.poses, len(frames), args)
    reg = WaypointRegistry(merge_radius=0.7, promote_conf=2.5, drop_conf=0.3)

    for tick, (frame, pose) in enumerate(zip(frames, poses), start=1):
        result = model.predict(frame, conf=args.conf, verbose=False)[0]
        seen: set[str] = set()
        footprint = pixel_ray_to_floor(k.cx, k.cy, k, pose)
        for box in result.boxes:
            name = model.names[int(box.cls)]
            label = DEFAULT_CLASSES.get(name)
            if label is None:
                continue
            x1, y1, x2, y2 = (float(v) for v in box.xyxy[0])
            foot = ((x1 + x2) / 2.0, y2)          # bottom-center = floor contact
            hit = pixel_ray_to_floor(foot[0], foot[1], k, pose)
            if hit is None:
                continue
            wp = reg.report(label, hit, confidence=float(box.conf), tick=tick)
            seen.add(wp.uid)
        if footprint is not None:
            reg.observe_area(footprint, 1.5, tick=tick, seen_uids=seen)
    return reg


def main() -> None:
    ap = argparse.ArgumentParser(description="detection -> named waypoints")
    ap.add_argument("--video", required=True)
    ap.add_argument("--model", default="yolo11n.pt")
    ap.add_argument("--poses", help="JSON [[x,y,height,yaw,pitch], ...] per frame")
    ap.add_argument("--hfov", type=float, default=68.0)
    ap.add_argument("--stride", type=int, default=5)
    ap.add_argument("--conf", type=float, default=0.35)
    ap.add_argument("--x", type=float, default=4.0)
    ap.add_argument("--y", type=float, default=0.5)
    ap.add_argument("--height", type=float, default=1.4)
    ap.add_argument("--yaw", type=float, default=1.5708)
    ap.add_argument("--pitch", type=float, default=0.5)
    ap.add_argument("--out", default="learning/out/waypoints.json")
    args = ap.parse_args()

    reg = run(args)
    targets = [{"label": w.label, "pos": [round(w.pos[0], 3), round(w.pos[1], 3)],
                "confidence": round(w.confidence, 2), "hits": w.hits}
               for w in reg.targets()]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(targets, indent=2))
    print(f"[run_detect] {len(targets)} waypoints -> {out}")
    for t in targets:
        print(f"  {t['label']:8} @ {t['pos']}  conf={t['confidence']}")


if __name__ == "__main__":
    main()
