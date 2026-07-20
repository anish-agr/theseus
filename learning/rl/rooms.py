"""Procedural rooms for RL train/eval — a curriculum in one function.

Determinism is by seed so train and held-out splits never overlap and
episodes replay exactly. Difficulty scales obstacle count and mover
count, matching the roadmap's static -> clutter -> movers curriculum.
"""

from __future__ import annotations

import random


def make_room(seed: int, *, size_m=(6.0, 4.5), cell: float = 0.05,
              n_obstacles: int = 4, n_movers: int = 0) -> tuple[dict, tuple]:
    """Return (room_dict, goal_xy). Walls line the perimeter; obstacles
    are random axis-aligned rectangles that avoid the start and goal
    pads. Connectivity is the caller's job (NavEnv retries)."""
    rng = random.Random(seed)
    w, h = size_m
    start = (0.5, h / 2.0)
    goal = (w - 0.5, h / 2.0)
    rects = [
        {"x": 0.0, "y": 0.0, "w": w, "h": 0.1, "label": "wall"},
        {"x": 0.0, "y": h - 0.1, "w": w, "h": 0.1, "label": "wall"},
        {"x": 0.0, "y": 0.0, "w": 0.1, "h": h, "label": "wall"},
        {"x": w - 0.1, "y": 0.0, "w": 0.1, "h": h, "label": "wall"},
    ]

    def clear_of_pads(x, y, rw, rh, pad=0.55) -> bool:
        for px, py in (start, goal):
            if (x - pad < px < x + rw + pad) and (y - pad < py < y + rh + pad):
                return False
        return True

    placed = 0
    tries = 0
    while placed < n_obstacles and tries < 200:
        tries += 1
        rw = rng.uniform(0.3, 1.2)
        rh = rng.uniform(0.3, 1.2)
        x = rng.uniform(0.3, w - 0.3 - rw)
        y = rng.uniform(0.3, h - 0.3 - rh)
        if clear_of_pads(x, y, rw, rh):
            rects.append({"x": round(x, 3), "y": round(y, 3),
                          "w": round(rw, 3), "h": round(rh, 3),
                          "label": "obstacle"})
            placed += 1

    movers = []
    for _ in range(n_movers):
        mx = rng.uniform(w * 0.35, w * 0.7)
        y0, y1 = 0.6, h - 0.6
        movers.append({"pts": [[round(mx, 3), y0], [round(mx, 3), y1]],
                       "speed": rng.uniform(0.3, 0.6), "radius": 0.28,
                       "label": "person"})

    room = {
        "name": f"rl-{seed}", "size_m": [w, h], "cell": cell,
        "start": [start[0], start[1]], "start_heading": 0.0,
        "rects": rects, "movers": movers,
    }
    return room, goal


CURRICULUM = {
    "empty":   dict(n_obstacles=0, n_movers=0),
    "static":  dict(n_obstacles=4, n_movers=0),
    "clutter": dict(n_obstacles=7, n_movers=0),
    "movers1": dict(n_obstacles=5, n_movers=1),
    "movers3": dict(n_obstacles=5, n_movers=3),
}
