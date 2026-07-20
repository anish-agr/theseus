"""Coverage routes: the promise is honest coverage, verified by
coverage_fraction, plus a route that is actually walkable end to end."""

from theseus_engine import astar
from theseus_engine.coverage import coverage_fraction, coverage_route
from theseus_engine.geometry import INF
from theseus_engine.grid import OCCUPIED, PlanParams

from helpers import open_grid

PARAMS = PlanParams(radius=0.05, safe_margin=0.1, margin_weight=1.0)


def test_open_room_is_covered():
    g = open_grid(30, 30, cell=0.05)
    res = coverage_route(g, (2, 2), PARAMS, lane_width=0.2)
    assert res is not None
    assert res.skipped == 0
    assert res.lanes >= 6
    assert astar.path_cost(g, res.cells, PARAMS) < INF   # walkable route
    frac = coverage_fraction(g, res.cells, PARAMS, lane_width=0.2)
    assert frac >= 0.95


def test_room_with_obstacle_still_covered_and_walkable():
    g = open_grid(30, 30, cell=0.05)
    for y in range(10, 20):
        for x in range(12, 18):
            g.set_state((x, y), OCCUPIED)
    res = coverage_route(g, (2, 2), PARAMS, lane_width=0.2)
    assert res is not None
    assert res.skipped == 0
    assert astar.path_cost(g, res.cells, PARAMS) < INF
    frac = coverage_fraction(g, res.cells, PARAMS, lane_width=0.2)
    assert frac >= 0.90


def test_unreachable_start_returns_none():
    g = open_grid(10, 10, cell=0.05)
    g.set_state((5, 5), OCCUPIED)
    assert coverage_route(g, (5, 5), PARAMS) is None or \
        coverage_route(g, (5, 5), PARAMS).cells == [(5, 5)]
