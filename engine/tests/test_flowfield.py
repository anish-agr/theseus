"""Flow fields must agree exactly with A* — same canonical cost model,
so distance(start) for a single goal IS the A* optimal cost. That
property, checked across random worlds, is what lets evacuation mode
trust the field."""

import pytest

from theseus_engine import astar
from theseus_engine.flowfield import FlowField
from theseus_engine.geometry import INF
from theseus_engine.grid import PlanParams

from helpers import make_random_grid, pick_free_pair

PARAMS = PlanParams(radius=0.05, safe_margin=0.2, margin_weight=1.0)


@pytest.mark.parametrize("seed", range(12))
def test_single_goal_distance_equals_astar_cost(seed):
    g = make_random_grid(seed)
    pair = pick_free_pair(seed, g, PARAMS)
    if pair is None:
        pytest.skip("degenerate grid")
    start, goal = pair
    ff = FlowField.build(g, [goal], PARAMS)
    ref = astar.plan(g, start, goal, PARAMS)
    if ref is None:
        assert ff.distance(start) == INF
    else:
        assert ff.distance(start) == pytest.approx(ref.cost, abs=1e-9)


@pytest.mark.parametrize("seed", range(6))
def test_multi_goal_distance_is_min_over_goals(seed):
    g = make_random_grid(seed, density=0.2)
    cells = [(x, y) for y in range(g.height) for x in range(g.width)
             if g.traversable((x, y), PARAMS)]
    if len(cells) < 4:
        pytest.skip("degenerate grid")
    goals = [cells[7 % len(cells)], cells[len(cells) // 2], cells[-3]]
    start = cells[len(cells) // 3]
    ff = FlowField.build(g, goals, PARAMS)
    costs = [r.cost for goal in goals
             if (r := astar.plan(g, start, goal, PARAMS)) is not None]
    if not costs:
        assert ff.distance(start) == INF
    else:
        assert ff.distance(start) == pytest.approx(min(costs), abs=1e-9)


@pytest.mark.parametrize("seed", range(8))
def test_route_from_descends_to_a_goal_at_field_cost(seed):
    g = make_random_grid(seed)
    pair = pick_free_pair(seed + 100, g, PARAMS)
    if pair is None:
        pytest.skip("degenerate grid")
    start, goal = pair
    ff = FlowField.build(g, [goal], PARAMS)
    route = ff.route_from(start)
    if ff.distance(start) == INF:
        assert route is None
    else:
        assert route is not None
        assert route.cells[0] == start
        assert route.cells[-1] == goal
        assert astar.path_cost(g, route.cells, PARAMS) == \
            pytest.approx(ff.distance(start), abs=1e-9)


def test_goal_cell_itself_reads_zero_and_next_step_none():
    g = make_random_grid(3)
    pair = pick_free_pair(3, g, PARAMS)
    if pair is None:
        pytest.skip("degenerate grid")
    _, goal = pair
    ff = FlowField.build(g, [goal], PARAMS)
    assert ff.distance(goal) == 0.0
    assert ff.next_step(goal) is None
