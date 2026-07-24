"""One world model, many solvers — the pitch, runnable.

    python engine/scripts/showcase.py

Builds the studio apartment's ground-truth map once, then answers a
string of genuinely useful spatial questions with the solvers the engine
already has. No new algorithms here — that is the point.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from theseus_engine import astar                                  # noqa: E402
from theseus_engine.coverage import coverage_fraction, coverage_route  # noqa: E402
from theseus_engine.demo import STUDIO                            # noqa: E402
from theseus_engine.flowfield import FlowField                    # noqa: E402
from theseus_engine.grid import PlanParams                        # noqa: E402
from theseus_engine.queries import fits_through, nearest_semantic  # noqa: E402
from theseus_engine.sim import Simulator                          # noqa: E402


def main() -> None:
    params = PlanParams(radius=0.28, safe_margin=0.5, margin_weight=1.2)
    sim = Simulator(STUDIO, params)
    grid = sim.truth                      # fully-known map of the studio
    door = grid.world_to_cell(tuple(STUDIO["waypoints"]["door"]))
    fridge_w = tuple(STUDIO["waypoints"]["fridge"])

    print("=== Theseus solver showcase -- studio apartment (8 x 6 m) ===\n")

    # 1. semantic query: nearest seat from the door
    route = nearest_semantic(grid, door, "couch", params)
    print(f"1. 'Take me to the couch' from the door:"
          f"  {len(route.cells)} cells, cost {route.cost:.2f} m-equiv"
          if route else "1. no couch reachable")

    # 2. fit-through: will furniture make it door -> fridge?
    plan = astar.plan(grid, door, grid.world_to_cell(fridge_w), params)
    smooth = astar.smooth(grid, plan.cells, params)
    for width in (0.5, 0.9):
        ok, pinch, narrowest = fits_through(grid, smooth, width)
        verdict = "YES" if ok else f"NO -- pinch near ({pinch[0]:.1f},{pinch[1]:.1f})"
        print(f"2. Would a {width:.1f} m-wide couch fit door->fridge? "
              f"{verdict} (narrowest {narrowest:.2f} m)")

    # 3. evacuation flow field: exit = the door, from anywhere
    ff = FlowField.build(grid, [door], params)
    for name, w in STUDIO["waypoints"].items():
        if name == "door":
            continue
        c = grid.world_to_cell(tuple(w))
        r = ff.route_from(c)
        print(f"3. Exit route from {name}: "
              f"{'%.2f m-equiv, %d steps' % (r.cost, len(r.cells)) if r else 'CUT OFF'}")

    # 4. coverage: patrol the whole floor
    cov = coverage_route(grid, door, params, lane_width=0.6)
    frac = coverage_fraction(grid, cov.cells, params, lane_width=0.6)
    print(f"4. Patrol sweep: {len(cov.cells)} cells across {cov.lanes} lanes, "
          f"covers {frac:.0%} of reachable floor")

    print("\nSame grid, four features. That's the spatial-OS thesis.")


if __name__ == "__main__":
    main()
