"""Frontier detection and target selection. The unreachable-frontier
case matters most: a frontier visible across a wall must never be
chased, because travel cost — not straight-line distance — ranks it."""

from theseus_engine.frontier import clusters, frontier_cells, select_target
from theseus_engine.grid import FREE, OCCUPIED, OccupancyGrid, PlanParams

PARAMS = PlanParams(radius=0.05, safe_margin=0.15, margin_weight=1.0)


def half_known_grid() -> OccupancyGrid:
    """Columns x < 8 known FREE, the rest UNKNOWN."""
    g = OccupancyGrid(20, 20, 0.05)
    for y in range(20):
        for x in range(8):
            g.set_state((x, y), FREE)
    return g


def test_frontier_is_exactly_the_known_unknown_boundary():
    g = half_known_grid()
    cells = frontier_cells(g)
    assert cells, "expected a frontier"
    assert all(c[0] == 7 for c in cells)   # only the boundary column
    assert len(cells) == 20
    # out-of-bounds reads OCCUPIED, not UNKNOWN: edges are not frontiers
    comp = clusters(cells, min_size=3)
    assert len(comp) == 1


def test_small_clusters_are_dropped_as_noise():
    g = half_known_grid()
    g.set_state((15, 15), FREE)  # isolated speck surrounded by unknown
    comp = clusters(frontier_cells(g), min_size=3)
    assert len(comp) == 1        # the speck (size 1) is gone
    assert all(c[0] == 7 for c in comp[0])


def test_select_target_picks_reachable_boundary():
    g = half_known_grid()
    t = select_target(g, (1, 10), PARAMS, min_cluster=3)
    assert t is not None
    assert t.cell[0] == 7
    assert abs(t.cell[1] - 10) <= 2      # nearest member is straight ahead
    assert t.cluster_size == 20


def test_fully_known_world_has_no_targets():
    g = OccupancyGrid(12, 12, 0.05)
    for y in range(12):
        for x in range(12):
            g.set_state((x, y), FREE)
    assert frontier_cells(g) == []
    assert select_target(g, (5, 5), PARAMS) is None


def test_frontier_across_a_wall_is_not_chased():
    g = half_known_grid()
    for y in range(20):                   # solid wall right of known space
        g.set_state((10, y), OCCUPIED)
    for y in range(6, 12):                # known island beyond the wall
        for x in range(12, 15):
            g.set_state((x, y), FREE)
    t = select_target(g, (1, 10), PARAMS, min_cluster=3)
    assert t is not None
    assert t.cell[0] == 7                 # island frontier exists but is cut off
