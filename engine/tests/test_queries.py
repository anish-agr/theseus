"""Fit-through and nearest-semantic queries."""

import pytest

from theseus_engine.grid import OCCUPIED, OccupancyGrid, PlanParams
from theseus_engine.queries import corridor_profile, fits_through, nearest_semantic

from helpers import open_grid

PARAMS = PlanParams(radius=0.05, safe_margin=0.1, margin_weight=1.0)


def corridor_with_pinch() -> OccupancyGrid:
    """A 3 m x 1 m corridor (walls top and bottom) pinched at x = 1.5 m
    to a 2-cell (10 cm) gap."""
    g = open_grid(60, 20, cell=0.05)
    for x in range(60):
        g.set_state((x, 0), OCCUPIED, "wall")
        g.set_state((x, 19), OCCUPIED, "wall")
    for y in list(range(1, 9)) + list(range(11, 19)):
        g.set_state((30, y), OCCUPIED, "cabinet")
    return g


def test_corridor_width_away_from_pinch():
    g = corridor_with_pinch()
    line = [(0.5, 0.5), (1.0, 0.5)]      # mid-height, far from the pinch
    widths = [w for _s, w in corridor_profile(g, line)]
    assert min(widths) == pytest.approx(0.9, abs=0.11)  # ~1 m minus walls


def test_fits_through_flags_the_pinch():
    g = corridor_with_pinch()
    route = [(0.5, 0.5), (2.5, 0.5)]     # straight through the pinch
    ok, pinch, width = fits_through(g, route, width_m=0.4)
    assert ok is False
    assert width <= 0.2                   # the 10 cm gap, cell-quantized
    assert pinch is not None
    assert pinch[0] == pytest.approx(1.5, abs=0.2)

    ok2, pinch2, _w2 = fits_through(g, route, width_m=0.05, margin_m=0.0)
    assert ok2 is True and pinch2 is None


def test_wide_route_passes():
    g = corridor_with_pinch()
    route = [(0.3, 0.5), (1.2, 0.5)]     # stops before the pinch
    ok, pinch, width = fits_through(g, route, width_m=0.5)
    assert ok is True and pinch is None
    assert width >= 0.6


def test_nearest_semantic_routes_to_closest_instance():
    g = open_grid(40, 40, cell=0.05)
    near_seat = [(x, y) for y in range(20, 23) for x in range(28, 31)]
    far_seat = [(x, y) for y in range(2, 5) for x in range(35, 38)]
    for c in near_seat:
        g.set_state(c, OCCUPIED, "seat")
    for c in far_seat:
        g.set_state(c, OCCUPIED, "seat")
    res = nearest_semantic(g, (5, 20), "seat", PARAMS)
    assert res is not None
    end = res.cells[-1]

    def cheb_m(c, cells):
        return min(max(abs(c[0] - s[0]), abs(c[1] - s[1])) for s in cells) \
            * g.cell_size

    assert cheb_m(end, near_seat) <= 0.76      # within arm's reach of it
    assert cheb_m(end, near_seat) < cheb_m(end, far_seat)  # the CLOSE one
    assert g.labels.get(g.idx(end)) is None    # standing beside, not on

    assert nearest_semantic(g, (5, 20), "fridge", PARAMS) is None


def test_nearest_semantic_works_with_realistic_body_radius():
    """Regression: strictly-adjacent goal cells have ~one-cell clearance,
    so a real body radius made every object 'unreachable' until approach
    points were introduced (found by engine/scripts/showcase.py)."""
    body = PlanParams(radius=0.28, safe_margin=0.5, margin_weight=1.2)
    g = open_grid(80, 60, cell=0.06)
    for y in range(20, 34):
        for x in range(40, 50):
            g.set_state((x, y), OCCUPIED, "couch")
    res = nearest_semantic(g, (5, 5), "couch", body)
    assert res is not None
    end = res.cells[-1]
    assert g.traversable(end, body)            # you can actually stand there
    d = min(max(abs(end[0] - x), abs(end[1] - y))
            for y in range(20, 34) for x in range(40, 50)) * g.cell_size
    assert d <= 0.76
