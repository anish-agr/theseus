"""(partial, full) map pairs from the simulator — free training data.

A pair is made by dropping the sensor at a few random poses in a
procedurally generated room (rl/rooms.py) and sensing: `partial` is what
the world model knows after those glimpses, `full` is the ground truth.
The network's job is exactly the app's situation mid-scan: given this
much of the room, what is the rest?

Maps are (state ∈ {UNKNOWN, FREE, OCCUPIED}) grids, downsampled to a
fixed net-friendly resolution by the caller if needed. Pairs are fully
deterministic in `seed`, so datasets never need to be stored — only the
generator and a seed range are committed (train/held-out split = disjoint
seed ranges, same trick the RL lane uses)."""

from __future__ import annotations

import math
import random
from dataclasses import dataclass

from theseus_engine.grid import PlanParams
from theseus_engine.sim import Simulator

from rl.rooms import make_room


@dataclass
class MapPair:
    seed: int
    w: int
    h: int
    partial: list[int]   # states, row-major, UNKNOWN where unseen
    full: list[int]      # states, row-major, fully known truth
    known_fraction: float


def generate_pair(seed: int, *, n_views: int = 6, cell: float = 0.06,
                  difficulty: dict | None = None,
                  sensor_range: float = 3.0,
                  sensor_fov_deg: float = 100.0) -> MapPair:
    difficulty = difficulty or {"n_obstacles": 5, "n_movers": 0}
    room, _goal = make_room(seed, cell=cell, **difficulty)
    params = PlanParams(radius=0.28, safe_margin=0.5, margin_weight=1.2)
    sim = Simulator(room, params, sensor_range=sensor_range,
                    sensor_fov_deg=sensor_fov_deg)
    rng = random.Random(seed ^ 0x1A7B)

    free_cells = [(x, y) for y in range(sim.truth.height)
                  for x in range(sim.truth.width)
                  if sim.truth.state((x, y)) == 1
                  and sim.truth.clearance((x, y)) >= params.radius]
    for view in range(n_views):
        cx, cy = free_cells[rng.randrange(len(free_cells))]
        wx, wy = sim.truth.cell_center((cx, cy))
        heading = rng.uniform(-math.pi, math.pi)
        sim.pose = (wx, wy, heading)
        sim.tick += 1
        # sense twice from each pose: one free-observation is not enough
        # evidence to flip a cell out of UNKNOWN (bounded log-odds), and
        # a real scan lingers for several frames anyway
        sim.sense()
        sim.tick += 1
        sim.sense()

    w, h = sim.est.width, sim.est.height
    partial = [sim.est.state((x, y)) for y in range(h) for x in range(w)]
    full = [sim.truth.state((x, y)) for y in range(h) for x in range(w)]
    known = sum(1 for s in partial if s != 0) / len(partial)
    return MapPair(seed, w, h, partial, full, round(known, 4))


def unknown_indices(pair: MapPair) -> list[int]:
    """The prediction targets: cells the partial map does not know."""
    return [i for i, s in enumerate(pair.partial) if s == 0]
