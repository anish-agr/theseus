"""Grid snapshots: exact state/label round-trips and honest diffs."""

import pytest

from theseus_engine import serialize
from theseus_engine.grid import FREE, OCCUPIED, UNKNOWN, OccupancyGrid

from helpers import make_random_grid


def test_round_trip_preserves_states_and_labels():
    g = make_random_grid(5, w=24, h=18)
    g.set_state((3, 3), OCCUPIED, "fridge")
    g.set_state((10, 7), UNKNOWN)
    g2 = serialize.from_dict(serialize.to_dict(g))
    assert (g2.width, g2.height, g2.cell_size) == (g.width, g.height, g.cell_size)
    for y in range(g.height):
        for x in range(g.width):
            assert g2.state((x, y)) == g.state((x, y))
    assert g2.label((3, 3)) == "fridge"


def test_rle_is_actually_compact_for_structured_maps():
    g = OccupancyGrid(50, 50, 0.05)
    for y in range(50):
        for x in range(50):
            g.set_state((x, y), FREE)
    d = serialize.to_dict(g)
    assert len(d["states"]) <= 4          # one long run


def test_diff_reports_exactly_the_changes():
    g = make_random_grid(7, w=20, h=20)
    g2 = serialize.from_dict(serialize.to_dict(g))
    changed = [((2, 2), OCCUPIED), ((15, 4), FREE), ((9, 9), OCCUPIED)]
    for c, s in changed:
        g2.set_state(c, s, "box" if s == OCCUPIED else "")
    delta = serialize.diff(g, g2)
    assert {c for c, _a, _b in delta} == \
        {c for c, s in changed if g.state(c) != s}
    report = serialize.diff_report(g, g2)
    assert report["appeared"] >= 1
    assert "box" in report["by_label"]


def test_dimension_mismatch_and_bad_schema_raise():
    g = make_random_grid(1, w=10, h=10)
    h = make_random_grid(1, w=11, h=10)
    with pytest.raises(ValueError):
        serialize.diff(g, h)
    with pytest.raises(ValueError):
        serialize.from_dict({"schema": "nope/9"})


def test_save_load_file_round_trip(tmp_path):
    g = make_random_grid(9, w=16, h=12)
    p = serialize.save(g, tmp_path / "snap.json")
    g2 = serialize.load(p)
    assert serialize.diff(g, g2) == []
