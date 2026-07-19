import math

from theseus_engine import astar
from theseus_engine.grid import FREE, OCCUPIED, OccupancyGrid, PlanParams

from helpers import make_random_grid, pick_free_pair


def test_optimality_matches_dijkstra_across_seeds():
    """A* with the octile heuristic must equal Dijkstra (h=0) exactly —
    proves the heuristic admissible under the shaped cost model."""
    p = PlanParams(radius=0.0, safe_margin=0.3, margin_weight=1.5)
    checked = 0
    for seed in range(25):
        g = make_random_grid(seed, density=0.25)
        pair = pick_free_pair(seed, g, p)
        if pair is None:
            continue
        a = astar.plan(g, pair[0], pair[1], p, use_heuristic=True)
        d = astar.plan(g, pair[0], pair[1], p, use_heuristic=False)
        assert (a is None) == (d is None)
        if a is not None:
            assert math.isclose(a.cost, d.cost, rel_tol=1e-9, abs_tol=1e-9)
            assert math.isclose(astar.path_cost(g, a.cells, p), a.cost,
                                rel_tol=1e-9, abs_tol=1e-9)
            checked += 1
    assert checked >= 15  # the property must actually have been exercised


def test_unreachable_returns_none():
    g = OccupancyGrid(10, 10, 0.1)
    for y in range(10):
        for x in range(10):
            g.set_state((x, y), FREE)
    for y in range(10):
        g.set_state((5, y), OCCUPIED)
    p = PlanParams(radius=0.0, safe_margin=0.0)
    assert astar.plan(g, (2, 5), (8, 5), p) is None


def test_trivial_and_degenerate_cases():
    g = OccupancyGrid(5, 5, 0.1)
    for y in range(5):
        for x in range(5):
            g.set_state((x, y), FREE)
    p = PlanParams(radius=0.0, safe_margin=0.0)
    r = astar.plan(g, (2, 2), (2, 2), p)
    assert r is not None and r.cost == 0.0 and r.cells == [(2, 2)]
    g.set_state((4, 4), OCCUPIED)
    assert astar.plan(g, (0, 0), (4, 4), p) is None      # goal blocked
    assert astar.plan(g, (4, 4), (0, 0), p) is None      # start blocked


def test_no_corner_cutting_in_paths():
    g = OccupancyGrid(3, 3, 0.1)
    for y in range(3):
        for x in range(3):
            g.set_state((x, y), FREE)
    g.set_state((1, 0), OCCUPIED)
    g.set_state((0, 1), OCCUPIED)
    p = PlanParams(radius=0.0, safe_margin=0.0)
    assert astar.plan(g, (0, 0), (1, 1), p) is None  # only the cut diagonal exists


def test_smoothing_stays_safe_and_keeps_endpoints():
    p = PlanParams(radius=0.1, safe_margin=0.2)
    for seed in range(10):
        g = make_random_grid(seed + 100, density=0.2)
        pair = pick_free_pair(seed, g, p)
        if pair is None:
            continue
        r = astar.plan(g, pair[0], pair[1], p)
        if r is None:
            continue
        sm = astar.smooth(g, r.cells, p)
        assert sm[0] == g.cell_center(r.cells[0])
        assert sm[-1] == g.cell_center(r.cells[-1])
        assert len(sm) <= len(r.cells)
        for i in range(len(sm) - 1):
            assert astar.corridor_clear(g, sm[i], sm[i + 1], p)


def test_path_valid_detects_new_obstacle():
    g = OccupancyGrid(12, 5, 0.1)
    for y in range(5):
        for x in range(12):
            g.set_state((x, y), FREE)
    p = PlanParams(radius=0.0, safe_margin=0.0)
    r = astar.plan(g, (0, 2), (11, 2), p)
    assert r is not None and astar.path_valid(g, r.cells, p)
    g.set_state((6, 2), OCCUPIED)
    assert not astar.path_valid(g, r.cells, p)
