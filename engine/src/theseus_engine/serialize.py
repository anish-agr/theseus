"""Grid snapshots: save / load / diff — the seed of the M2 sidecar format.

What persists is the MAP, not the sensor history: derived cell states and
semantic labels round-trip exactly; log-odds are collapsed to each
state's saturation value on load (identical to set_state, which the
simulators use too). Run-length encoding keeps a 19k-cell studio under a
few KB of JSON.

diff() is the "what changed since yesterday" kernel: load yesterday's
sidecar, diff against today's model, get labeled changes. On-device this
becomes per-chunk hashes so unchanged chunks never load — but the
semantics are frozen here first.
"""

from __future__ import annotations

import json
from pathlib import Path

from .geometry import Cell
from .grid import OccupancyGrid, UNKNOWN

SCHEMA = "theseus-grid/1"


def to_dict(grid: OccupancyGrid) -> dict:
    states: list[int] = []
    run_state = grid.state((0, 0))
    run_len = 0
    for y in range(grid.height):
        for x in range(grid.width):
            s = grid.state((x, y))
            if s == run_state:
                run_len += 1
            else:
                states.extend((run_state, run_len))
                run_state, run_len = s, 1
    states.extend((run_state, run_len))
    return {
        "schema": SCHEMA,
        "w": grid.width,
        "h": grid.height,
        "cell": grid.cell_size,
        "origin": [grid.origin[0], grid.origin[1]],
        "states": states,
        "labels": {str(i): lab for i, lab in sorted(grid.labels.items())},
    }


def from_dict(d: dict) -> OccupancyGrid:
    if d.get("schema") != SCHEMA:
        raise ValueError(f"unsupported grid schema: {d.get('schema')!r}")
    g = OccupancyGrid(d["w"], d["h"], d["cell"],
                      (d["origin"][0], d["origin"][1]))
    i = 0
    rle = d["states"]
    for k in range(0, len(rle), 2):
        state, run = rle[k], rle[k + 1]
        if state != UNKNOWN:  # grids start all-UNKNOWN
            for j in range(i, i + run):
                g.set_state((j % g.width, j // g.width), state)
        i += run
    if i != g.width * g.height:
        raise ValueError("RLE state stream does not match grid size")
    for key, lab in d.get("labels", {}).items():
        g.labels[int(key)] = lab
    return g


def save(grid: OccupancyGrid, path: str | Path) -> Path:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(to_dict(grid), separators=(",", ":")),
                 encoding="utf-8")
    return p


def load(path: str | Path) -> OccupancyGrid:
    return from_dict(json.loads(Path(path).read_text(encoding="utf-8")))


def diff(a: OccupancyGrid, b: OccupancyGrid) -> list[tuple[Cell, int, int]]:
    """Cells whose derived state differs: (cell, state_in_a, state_in_b)."""
    if (a.width, a.height) != (b.width, b.height):
        raise ValueError("grids must share dimensions to diff")
    out: list[tuple[Cell, int, int]] = []
    for y in range(a.height):
        for x in range(a.width):
            sa, sb = a.state((x, y)), b.state((x, y))
            if sa != sb:
                out.append(((x, y), sa, sb))
    return out


def diff_report(a: OccupancyGrid, b: OccupancyGrid) -> dict:
    """Human-oriented summary of a->b: what appeared, what vanished,
    grouped by semantic label where one is known."""
    from .grid import OCCUPIED
    appeared = vanished = 0
    by_label: dict[str, int] = {}
    for c, sa, sb in diff(a, b):
        if sb == OCCUPIED and sa != OCCUPIED:
            appeared += 1
        elif sa == OCCUPIED and sb != OCCUPIED:
            vanished += 1
        else:
            continue
        lab = b.label(c) or a.label(c) or "?"
        by_label[lab] = by_label.get(lab, 0) + 1
    return {"appeared": appeared, "vanished": vanished, "by_label": by_label}
