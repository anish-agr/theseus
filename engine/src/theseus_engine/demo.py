"""Demo scenarios: end-to-end runs that produce viewer traces and goldens.

Two rooms:

- "mini"   — small, fast, fully deterministic; its trace hash is the
             golden fixture (tests/test_golden.py). If an intentional
             engine change alters behavior, regenerate with
             `python engine/scripts/generate.py` and commit the new hash.
- "studio" — the showcase: map a furnished studio apartment with a
             limited-FOV sensor, then guide a "human" from the door to
             the fridge while a person paces across the route, forcing
             live D* Lite reroutes. Open tools/viewer/index.html to watch.
"""

from __future__ import annotations

import json
from pathlib import Path

from . import astar
from .controller import NavController
from .grid import FREE, PlanParams
from .sim import Simulator
from .trace import TraceWriter

MINI = {
    "name": "mini",
    "size_m": [5.0, 4.0],
    "cell": 0.05,
    "start": [0.6, 0.6],
    "start_heading": 0.0,
    "rects": [
        {"x": 0.0, "y": 0.0, "w": 5.0, "h": 0.1, "label": "wall"},
        {"x": 0.0, "y": 3.9, "w": 5.0, "h": 0.1, "label": "wall"},
        {"x": 0.0, "y": 0.0, "w": 0.1, "h": 4.0, "label": "wall"},
        {"x": 4.9, "y": 0.0, "w": 0.1, "h": 4.0, "label": "wall"},
        {"x": 2.0, "y": 1.5, "w": 1.0, "h": 0.9, "label": "crate"},
    ],
    "waypoints": {"target": [4.3, 0.8]},
    "scan_pts": [[4.3, 0.7], [4.3, 3.3], [0.7, 3.3]],
    "movers": [{"pts": [[3.5, 0.7], [3.5, 3.3]], "speed": 0.4,
                "radius": 0.22, "label": "person"}],
    "goal": "target",
}

STUDIO = {
    "name": "studio",
    "size_m": [8.0, 6.0],
    "cell": 0.06,
    "start": [0.6, 3.0],
    "start_heading": 0.0,
    "rects": [
        {"x": 0.0, "y": 0.0, "w": 8.0, "h": 0.1, "label": "wall"},
        {"x": 0.0, "y": 5.9, "w": 8.0, "h": 0.1, "label": "wall"},
        {"x": 0.0, "y": 0.0, "w": 0.1, "h": 6.0, "label": "wall"},
        {"x": 7.9, "y": 0.0, "w": 0.1, "h": 6.0, "label": "wall"},
        {"x": 1.0, "y": 4.2, "w": 2.0, "h": 1.4, "label": "bed"},
        {"x": 3.6, "y": 2.6, "w": 1.2, "h": 1.0, "label": "table"},
        {"x": 2.2, "y": 0.3, "w": 2.6, "h": 0.8, "label": "couch"},
        {"x": 7.3, "y": 3.2, "w": 0.6, "h": 2.4, "label": "kitchen"},
        {"x": 5.2, "y": 5.5, "w": 2.0, "h": 0.4, "label": "shelf"},
    ],
    "waypoints": {"fridge": [6.9, 4.4], "door": [0.6, 3.0]},
    "scan_pts": [[1.5, 1.5], [4.0, 1.7], [6.6, 1.5], [6.3, 4.6], [1.2, 3.4]],
    "movers": [{"pts": [[5.6, 1.0], [5.6, 4.8]], "speed": 0.45,
                "radius": 0.3, "label": "person"}],
    "goal": "fridge",
}


def run_room(room: dict, *, sensor_range: float = 3.0,
             sensor_fov_deg: float = 110.0, guide_ticks: int = 2200,
             params: PlanParams | None = None) -> tuple[TraceWriter, dict]:
    params = params or PlanParams(radius=0.28, safe_margin=0.5,
                                  margin_weight=1.2)
    sim = Simulator(room, params, sensor_range=sensor_range,
                    sensor_fov_deg=sensor_fov_deg)
    trace = TraceWriter({
        "name": room["name"],
        "cell": room["cell"],
        "w": sim.est.width,
        "h": sim.est.height,
        "size_m": room["size_m"],
        "dt": sim.dt,
        "radius": params.radius,
        "sensor": {"range": sensor_range, "fov_deg": sensor_fov_deg},
        "waypoints": room.get("waypoints", {}),
        "furniture": [[r["x"], r["y"], r["w"], r["h"], r.get("label", "")]
                      for r in room.get("rects", [])],
        "scan_pts": room.get("scan_pts", []),
    })
    nav = NavController(sim, params, trace)
    goal = tuple(room["waypoints"][room["goal"]])
    goal_cell = sim.est.world_to_cell(goal)

    def mapped_enough() -> bool:
        return astar.plan(sim.est, nav._cell(), goal_cell, params) is not None

    nav.run_mapping(room.get("scan_pts", []), laps=2, done_check=mapped_enough)
    arrived = nav.run_guidance(goal, max_ticks=guide_ticks)

    summary = {
        "room": room["name"],
        "arrived": arrived,
        "sim_seconds": round(sim.tick * sim.dt, 1),
        "frames": nav.frames,
        "replans": nav.replans,
        "collisions": sim.collisions,
        "final_state": nav.fsm.state.value,
    }
    return trace, summary


def _known_free_fraction(sim: Simulator, params: PlanParams) -> float:
    """How much of the truly walkable floor the agent's map knows FREE."""
    truth, est = sim.truth, sim.est
    total = known = 0
    for y in range(truth.height):
        for x in range(truth.width):
            c = (x, y)
            if truth.state(c) == FREE and truth.clearance(c) >= params.radius:
                total += 1
                if est.state(c) == FREE:
                    known += 1
    return known / max(1, total)


def run_explore_room(room: dict, *, sensor_range: float = 3.0,
                     sensor_fov_deg: float = 110.0,
                     params: PlanParams | None = None) -> tuple[TraceWriter, dict]:
    """Frontier-explore a quiet copy of the room (movers removed): the
    virtual-agent auto-mapping showcase."""
    room = {**room, "movers": [], "name": room["name"] + "-explore"}
    params = params or PlanParams(radius=0.28, safe_margin=0.5,
                                  margin_weight=1.2)
    sim = Simulator(room, params, sensor_range=sensor_range,
                    sensor_fov_deg=sensor_fov_deg)
    trace = TraceWriter({
        "name": room["name"],
        "cell": room["cell"],
        "w": sim.est.width,
        "h": sim.est.height,
        "size_m": room["size_m"],
        "dt": sim.dt,
        "radius": params.radius,
        "sensor": {"range": sensor_range, "fov_deg": sensor_fov_deg},
        "waypoints": room.get("waypoints", {}),
        "furniture": [[r["x"], r["y"], r["w"], r["h"], r.get("label", "")]
                      for r in room.get("rects", [])],
        "scan_pts": [],
    })
    nav = NavController(sim, params, trace)
    stats = nav.run_explore()
    summary = {
        "room": room["name"],
        "targets": stats["targets"],
        "known_free_fraction": round(_known_free_fraction(sim, params), 3),
        "sim_seconds": round(sim.tick * sim.dt, 1),
        "frames": nav.frames,
        "replans": nav.replans,
        "collisions": sim.collisions,
        "final_state": nav.fsm.state.value,
    }
    return trace, summary


def run_mini_explore() -> tuple[TraceWriter, dict]:
    return run_explore_room(MINI, sensor_range=2.5, sensor_fov_deg=120.0)


def run_studio_explore() -> tuple[TraceWriter, dict]:
    return run_explore_room(STUDIO, sensor_range=3.2, sensor_fov_deg=110.0)


def run_mini() -> tuple[TraceWriter, dict]:
    return run_room(MINI, sensor_range=2.5, sensor_fov_deg=120.0,
                    guide_ticks=1200)


def run_studio() -> tuple[TraceWriter, dict]:
    return run_room(STUDIO, sensor_range=3.2, sensor_fov_deg=110.0,
                    guide_ticks=2200)


def main() -> None:
    root = Path(__file__).resolve().parents[3]
    rooms_dir = root / "fixtures" / "rooms"
    rooms_dir.mkdir(parents=True, exist_ok=True)
    for room in (MINI, STUDIO):
        (rooms_dir / f"{room['name']}.json").write_text(
            json.dumps(room, indent=2), encoding="utf-8")

    trace, summary = run_mini()
    golden_dir = root / "fixtures" / "golden"
    trace.save(golden_dir / "mini-trace.jsonl")
    (golden_dir / "mini.sha256").write_text(trace.sha256() + "\n",
                                            encoding="utf-8")
    print("mini  :", json.dumps(summary))

    trace, summary = run_studio()
    trace.save(root / "fixtures" / "demo" / "studio-trace.jsonl")
    trace.save(root / "tools" / "viewer" / "demo-trace.jsonl")
    print("studio:", json.dumps(summary))

    trace, summary = run_mini_explore()
    trace.save(golden_dir / "mini-explore-trace.jsonl")
    (golden_dir / "mini-explore.sha256").write_text(trace.sha256() + "\n",
                                                   encoding="utf-8")
    print("mini-explore  :", json.dumps(summary))

    trace, summary = run_studio_explore()
    trace.save(root / "fixtures" / "demo" / "explore-trace.jsonl")
    trace.save(root / "tools" / "viewer" / "explore-trace.jsonl")
    print("studio-explore:", json.dumps(summary))
    print("view explore: /tools/viewer/index.html?trace=explore-trace.jsonl")


if __name__ == "__main__":
    main()
