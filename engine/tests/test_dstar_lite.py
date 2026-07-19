"""The load-bearing test of the whole engine: D* Lite, replanning
incrementally through arbitrary world edits and start movements, must
produce paths of exactly the cost a fresh A* computes. If this file is
green, the incremental planner can be trusted; when the engine is ported
to Swift, port these tests first."""

import math
import random

from theseus_engine import astar
from theseus_engine.dstar_lite import DStarLite
from theseus_engine.grid import FREE, OCCUPIED, PlanParams

from helpers import make_random_grid, pick_free_pair


def _assert_agrees(g, ds, start, goal, p, ctx):
    got = ds.plan()
    want = astar.plan(g, start, goal, p)
    assert (got is None) == (want is None), f"{ctx}: reachability disagrees"
    if got is not None:
        assert math.isclose(got.cost, want.cost, rel_tol=1e-6, abs_tol=1e-6), \
            f"{ctx}: cost {got.cost} != A* {want.cost}"
        assert got.cells[0] == start and got.cells[-1] == goal
        assert math.isclose(astar.path_cost(g, got.cells, p), got.cost,
                            rel_tol=1e-9, abs_tol=1e-9)


def test_equivalence_under_random_mutations_and_start_moves():
    p = PlanParams(radius=0.0, safe_margin=0.25, margin_weight=1.2)
    exercised = 0
    for seed in range(12):
        g = make_random_grid(seed, w=28, h=28, density=0.22)
        pair = pick_free_pair(seed, g, p)
        if pair is None:
            continue
        start, goal = pair
        rng = random.Random(seed * 31 + 7)
        ds = DStarLite(g, start, goal, p)
        _assert_agrees(g, ds, start, goal, p, f"seed {seed} initial")
        for step in range(12):
            # toggle a random non-endpoint cell
            c = (rng.randrange(g.width), rng.randrange(g.height))
            if c in (start, goal):
                continue
            new = FREE if g.state(c) == OCCUPIED else OCCUPIED
            g.set_state(c, new)
            ds.notify_changed([c])
            # sometimes the agent also advances along its current path
            if step % 3 == 2:
                current = ds.plan()
                if current is not None and len(current.cells) > 1:
                    start = current.cells[1]
                    ds.update_start(start)
            _assert_agrees(g, ds, start, goal, p, f"seed {seed} step {step}")
            exercised += 1
    assert exercised >= 60


def test_blocking_and_reopening_the_only_corridor():
    from theseus_engine.grid import OccupancyGrid
    g = OccupancyGrid(15, 7, 0.1)
    for y in range(7):
        for x in range(15):
            g.set_state((x, y), FREE)
    for y in range(7):
        if y != 3:
            g.set_state((7, y), OCCUPIED)    # wall with one gap at y=3
    p = PlanParams(radius=0.0, safe_margin=0.0)
    ds = DStarLite(g, (1, 3), (13, 3), p)
    first = ds.plan()
    assert first is not None
    g.set_state((7, 3), OCCUPIED)            # close the gap
    ds.notify_changed([(7, 3)])
    assert ds.plan() is None
    g.set_state((7, 3), FREE)                # reopen it
    ds.notify_changed([(7, 3)])
    again = ds.plan()
    assert again is not None
    assert math.isclose(again.cost, first.cost, rel_tol=1e-9)


def test_goal_becoming_blocked_is_reported():
    from theseus_engine.grid import OccupancyGrid
    g = OccupancyGrid(8, 8, 0.1)
    for y in range(8):
        for x in range(8):
            g.set_state((x, y), FREE)
    p = PlanParams(radius=0.0, safe_margin=0.0)
    ds = DStarLite(g, (0, 0), (6, 6), p)
    assert ds.plan() is not None
    g.set_state((6, 6), OCCUPIED)
    ds.notify_changed([(6, 6)])
    assert ds.plan() is None
