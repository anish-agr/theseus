"""Golden fixture for the monocular-depth lane: the synthetic sweep must
recover a correct occupancy map (walls solid, interior free, occluded
box interior unknown) and produce a byte-identical trace.

Like the engine goldens, this freezes the projection+ingest behavior so
the on-device Swift port (M4) can be checked against it."""

from pathlib import Path

from theseus_engine.grid import FREE, OCCUPIED, UNKNOWN

from demo_depth import run

GOLDEN = Path(__file__).resolve().parents[2] / "fixtures" / "golden" / \
    "depth-mini.sha256"


def test_depth_lane_recovers_the_room_and_matches_golden():
    trace, grid, stats = run()

    def state(x, y):
        return grid.state(grid.world_to_cell((x, y)))

    # the pipeline's floor fit stays sane on every frame
    assert stats["floor_z_max_err"] < 0.6
    # interior is carved free; walls are solid; the box is seen only from
    # outside so its interior stays unknown (occlusion respected)
    assert state(2.0, 2.0) == FREE
    assert state(1.0, 2.0) == FREE
    assert state(0.02, 1.5) == OCCUPIED       # left wall
    assert state(2.0, 0.02) == OCCUPIED       # bottom wall
    assert state(3.98, 1.5) == OCCUPIED       # right wall
    assert state(2.0, 1.4) == UNKNOWN         # box interior, never observed
    assert stats["occ_cells"] > 200
    assert stats["free_cells"] > 3000

    assert GOLDEN.exists(), \
        "golden hash missing — run: python learning/demo_depth.py"
    assert trace.sha256() == GOLDEN.read_text().strip(), \
        "depth trace changed — if intentional, rerun demo_depth.py and commit"
