import math

from theseus_engine.geometry import INF, octile
from theseus_engine.grid import (FREE, OCCUPIED, UNKNOWN, OccupancyGrid,
                                 PlanParams)

from helpers import make_random_grid


def test_states_and_observation_dynamics():
    g = OccupancyGrid(4, 4, 0.1)
    c = (1, 1)
    assert g.state(c) == UNKNOWN
    assert g.observe(c, True) is True          # one hit flips unknown -> occupied
    assert g.state(c) == OCCUPIED
    changed = False
    for _ in range(4):                          # misses accumulate back to free
        changed = g.observe(c, False) or changed
    assert changed and g.state(c) == FREE
    for _ in range(50):                         # log-odds clamp holds
        g.observe(c, False)
    assert g.lo[g.idx(c)] >= -4.0 - 1e-9


def test_out_of_bounds_reads_occupied():
    g = OccupancyGrid(3, 3, 0.1)
    assert g.state((-1, 0)) == OCCUPIED
    assert g.state((0, 3)) == OCCUPIED


def test_clearance_matches_brute_force():
    g = make_random_grid(3, w=20, h=16, density=0.15)
    occupied = [(x, y) for y in range(16) for x in range(20)
                if g.state((x, y)) == OCCUPIED]
    assert occupied, "seed produced no obstacles"
    for y in range(16):
        for x in range(20):
            expect = min(octile((x, y), o) for o in occupied) * g.cell_size
            assert math.isclose(g.clearance((x, y)), expect, abs_tol=1e-9)


def test_clearance_cap():
    g = make_random_grid(4, w=20, h=16, density=0.1)
    exact = [g.clearance((x, y)) for y in range(16) for x in range(20)]
    g.clearance_cap = 0.3
    g.refresh_clearance(force=True)
    i = 0
    for y in range(16):
        for x in range(20):
            got = g.clearance((x, y))
            if exact[i] < 0.3:
                assert math.isclose(got, exact[i], abs_tol=1e-9)
            else:
                assert math.isclose(got, 0.3, abs_tol=1e-9)
            i += 1


def test_clearance_only_dirty_on_occupied_changes():
    g = OccupancyGrid(8, 8, 0.1)
    g.set_state((4, 4), OCCUPIED)
    g.clearance((0, 0))
    assert g._clear_dirty is False
    g.observe((1, 1), False)                    # unknown -> free: no effect
    assert g._clear_dirty is False
    g.observe((2, 2), True)                     # new obstacle: dirty
    assert g._clear_dirty is True


def test_traversable_respects_radius_and_unknown_policy():
    g = OccupancyGrid(10, 10, 0.05)
    for y in range(10):
        for x in range(10):
            g.set_state((x, y), FREE)
    for y in range(10):
        g.set_state((5, y), OCCUPIED)
    p = PlanParams(radius=0.09, safe_margin=0.2)
    assert not g.traversable((4, 5), p)         # 1 cell (0.05 m) from the wall
    assert g.traversable((3, 5), p)             # 2 cells (0.10 m) away
    g.set_state((2, 2), UNKNOWN)
    assert not g.traversable((2, 2), p)
    assert g.traversable((2, 2), PlanParams(radius=0.09, safe_margin=0.2,
                                            unknown_ok=True))


def test_edge_cost_rules():
    g = OccupancyGrid(4, 4, 0.1)
    for y in range(4):
        for x in range(4):
            g.set_state((x, y), FREE)
    p = PlanParams(radius=0.0, safe_margin=0.0)
    # cardinal vs diagonal lengths
    assert math.isclose(g.edge_cost((0, 0), (1, 0), p), 0.1)
    assert math.isclose(g.edge_cost((0, 0), (1, 1), p), 0.1 * math.sqrt(2))
    # into occupied: INF; out of occupied: INF
    g.set_state((1, 0), OCCUPIED)
    assert g.edge_cost((0, 0), (1, 0), p) == INF
    assert g.edge_cost((1, 0), (0, 0), p) == INF
    # corner cutting forbidden: (0,0)->(1,1) squeezes past (1,0)+(0,1)
    g.set_state((0, 1), OCCUPIED)
    assert g.edge_cost((0, 0), (1, 1), p) == INF


def test_cost_shaping_prefers_clearance():
    g = OccupancyGrid(9, 9, 0.1)
    for y in range(9):
        for x in range(9):
            g.set_state((x, y), FREE)
    for y in range(9):
        g.set_state((0, y), OCCUPIED)
    p = PlanParams(radius=0.0, safe_margin=0.35, margin_weight=2.0)
    assert g.cell_cost((1, 4), p) > g.cell_cost((3, 4), p) >= 1.0
    assert math.isclose(g.cell_cost((8, 4), p), 1.0)


def test_min_clearance_along():
    g = OccupancyGrid(20, 10, 0.1)
    for y in range(10):
        for x in range(20):
            g.set_state((x, y), FREE)
    for y in range(10):
        g.set_state((10, y), OCCUPIED)
    wide = g.min_clearance_along((0.15, 0.55), (0.85, 0.55))
    narrow = g.min_clearance_along((0.15, 0.55), (0.95, 0.55))
    assert narrow <= wide
    assert g.min_clearance_along((0.55, 0.15), (0.55, 0.95)) > 0.0
