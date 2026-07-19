import math

from theseus_engine.grid import OCCUPIED, PlanParams
from theseus_engine.steering import VFHSteering

from helpers import open_grid

P = PlanParams(radius=0.1, safe_margin=0.2)


def test_open_space_goes_toward_goal():
    g = open_grid(80, 80)                      # 4 x 4 m, empty
    vfh = VFHSteering(P, lookahead=1.5)
    d = vfh.decide(g, (2.0, 2.0, 0.0), goal_bearing=0.0)
    assert not d.blocked and d.speed > 0
    assert abs(d.heading) <= math.pi / 18 + 1e-9   # within one 10-degree sector
    assert d.free_dist >= 1.0


def test_never_chooses_an_inadmissible_sector():
    g = open_grid(80, 80)
    for y in range(80):                        # wall at x = 2.0 m
        g.set_state((40, y), OCCUPIED)
    vfh = VFHSteering(P, lookahead=1.5, min_free=0.4)
    # 0.35 m from the wall: straight ahead offers < min_free of room, so an
    # almost-parallel sector must win even though the goal is dead ahead
    d = vfh.decide(g, (1.65, 2.0, 0.0), goal_bearing=0.0)
    assert not d.blocked
    assert vfh.ray_free(g, (1.65, 2.0), d.heading) >= 0.4 - 1e-9
    assert abs(d.heading) > math.pi / 6        # clearly not into the wall


def test_boxed_in_reports_blocked():
    g = open_grid(40, 40)
    # seal a 1 x 1 m box around the agent
    for x in range(8, 13):
        g.set_state((x, 8), OCCUPIED)
        g.set_state((x, 12), OCCUPIED)
    for y in range(8, 13):
        g.set_state((8, y), OCCUPIED)
        g.set_state((12, y), OCCUPIED)
    vfh = VFHSteering(P, lookahead=1.5, min_free=0.4)
    d = vfh.decide(g, (0.5, 0.5, 0.0))         # center of the box (cells 10,10)
    assert d.blocked and d.speed == 0.0


def test_hysteresis_holds_heading_under_jitter():
    g = open_grid(80, 80)
    vfh = VFHSteering(P, lookahead=1.5, commit_ticks=4, switch_margin=0.3)
    headings = []
    for i in range(6):
        jitter = 0.06 if i % 2 == 0 else -0.06
        d = vfh.decide(g, (2.0, 2.0, 0.0), goal_bearing=jitter)
        headings.append(d.heading)
    spread = max(headings) - min(headings)
    assert spread <= (2 * math.pi / 36) + 1e-9  # stayed within one sector
