"""Lane D training: a small UNet vs the nearest-known baseline.

    pip install -r learning/requirements.txt   # torch
    python learning/inpaint/train_unet.py --pairs 400 --epochs 12

Input:  2 channels (known-free mask, known-occupied mask), fixed 96x96
        center-crop/pad of the partial map.
Output: per-cell occupancy logit; loss is masked to cells that were
        UNKNOWN in the input (predicting what you know is not learning).
Report: held-out accuracy + occupied-IoU next to the baseline's numbers
        on the SAME seeds — the bar it has to clear (see test_inpaint).
Deploy: advisory only; predicted-free is never traversable (grid.py).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "engine" / "src"))

from inpaint.baseline import inpaint_nearest
from inpaint.dataset import generate_pair
from inpaint.metrics import evaluate, score_pairs

SIZE = 96


def _require():
    try:
        import torch  # noqa: F401
    except Exception:
        sys.exit("[inpaint] missing torch. Install the lane:\n"
                 "    pip install -r learning/requirements.txt")


def to_tensors(pair, torch):
    """(2, S, S) input planes + (S, S) target/mask, center-cropped."""
    import torch.nn.functional as F
    w, h = pair.w, pair.h
    part = torch.tensor(pair.partial, dtype=torch.float32).view(h, w)
    full = torch.tensor(pair.full, dtype=torch.float32).view(h, w)
    x = torch.stack([(part == 1).float(), (part == 2).float()])
    y = (full == 2).float()
    m = (part == 0).float()
    pw, ph = max(0, SIZE - w), max(0, SIZE - h)
    x = F.pad(x, (0, pw, 0, ph))[:, :SIZE, :SIZE]
    y = F.pad(y.unsqueeze(0), (0, pw, 0, ph))[0, :SIZE, :SIZE]
    m = F.pad(m.unsqueeze(0), (0, pw, 0, ph))[0, :SIZE, :SIZE]
    return x, y, m


def build_unet(torch):
    import torch.nn as nn

    def block(i, o):
        return nn.Sequential(nn.Conv2d(i, o, 3, padding=1), nn.ReLU(),
                             nn.Conv2d(o, o, 3, padding=1), nn.ReLU())

    class UNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.d1 = block(2, 16)
            self.d2 = block(16, 32)
            self.bott = block(32, 64)
            self.u2 = block(64 + 32, 32)
            self.u1 = block(32 + 16, 16)
            self.head = nn.Conv2d(16, 1, 1)
            self.pool = nn.MaxPool2d(2)
            self.up = nn.Upsample(scale_factor=2, mode="nearest")

        def forward(self, x):
            a = self.d1(x)
            b = self.d2(self.pool(a))
            c = self.bott(self.pool(b))
            x = self.u2(torch.cat([self.up(c), b], dim=1))
            x = self.u1(torch.cat([self.up(x), a], dim=1))
            return self.head(x)[:, 0]

    return UNet()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", type=int, default=400)
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--out", default="learning/inpaint/runs")
    args = ap.parse_args()
    _require()
    import torch

    train_pairs = [generate_pair(s) for s in range(args.pairs)]
    held_seeds = range(10_000, 10_030)         # disjoint from training
    held_pairs = [generate_pair(s) for s in held_seeds]

    data = [to_tensors(p, torch) for p in train_pairs]
    net = build_unet(torch)
    opt = torch.optim.Adam(net.parameters(), lr=args.lr)
    bce = torch.nn.BCEWithLogitsLoss(reduction="none")

    for epoch in range(args.epochs):
        total = 0.0
        for i in range(0, len(data), args.batch):
            xs = torch.stack([d[0] for d in data[i:i + args.batch]])
            ys = torch.stack([d[1] for d in data[i:i + args.batch]])
            ms = torch.stack([d[2] for d in data[i:i + args.batch]])
            loss = (bce(net(xs), ys) * ms).sum() / ms.sum().clamp(min=1.0)
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss.detach())
        print(f"epoch {epoch + 1}/{args.epochs} masked-BCE "
              f"{total / max(1, len(data) // args.batch):.4f}")

    def unet_method(partial, w, h):
        pair = type("P", (), {"partial": partial, "full": partial,
                              "w": w, "h": h})
        x, _y, _m = to_tensors(pair, torch)
        with torch.no_grad():
            occ = torch.sigmoid(net(x.unsqueeze(0))[0]) > 0.5
        out = list(partial)
        for i, s in enumerate(partial):
            yy, xx = divmod(i, w)
            if s == 0 and yy < SIZE and xx < SIZE:
                out[i] = 2 if bool(occ[yy, xx]) else 1
        return out

    unet_score = score_pairs(unet_method, held_pairs)
    base_score = evaluate(inpaint_nearest, held_seeds)
    print(f"\nheld-out (n={len(held_pairs)})")
    print(f"  baseline: acc {base_score.accuracy:.3f}  "
          f"IoU_occ {base_score.iou_occupied:.3f}")
    print(f"  unet    : acc {unet_score.accuracy:.3f}  "
          f"IoU_occ {unet_score.iou_occupied:.3f}")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    torch.save(net.state_dict(), out / "unet.pt")
    print(f"saved {out / 'unet.pt'}")


if __name__ == "__main__":
    main()
