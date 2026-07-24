"""Classical inpainting baseline: nearest-known-cell voting.

Every UNKNOWN cell takes the state of its nearest known cell (multi-
source BFS from all known cells at once, 8-connected, deterministic
tie-breaking by scan order). It captures the two big priors for free —
free space is contiguous, and walls continue — and costs O(n) with no
dependencies. The UNet (train_unet.py) must beat THIS on held-out rooms,
not an all-free strawman, before it earns a place in the app."""

from __future__ import annotations

from collections import deque

from .dataset import MapPair

_NBR8 = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))


def inpaint_nearest(partial: list[int], w: int, h: int) -> list[int]:
    """Fill UNKNOWN (0) cells with the state of the nearest known cell.
    A fully-unknown map comes back unchanged."""
    out = list(partial)
    q: deque[tuple[int, int]] = deque()
    for y in range(h):
        base = y * w
        for x in range(w):
            if out[base + x] != 0:
                q.append((x, y))
    while q:
        x, y = q.popleft()
        s = out[y * w + x]
        for dx, dy in _NBR8:
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and out[ny * w + nx] == 0:
                out[ny * w + nx] = s
                q.append((nx, ny))
    return out


def predict_all_free(partial: list[int], w: int, h: int) -> list[int]:
    """The strawman: everything unknown is free. Kept as the floor any
    real method must clear (rooms are mostly free, so raw accuracy alone
    flatters it — which is why the metrics track occupied-IoU too)."""
    return [1 if s == 0 else s for s in partial]


def apply(pair: MapPair, method=inpaint_nearest) -> list[int]:
    return method(pair.partial, pair.w, pair.h)
