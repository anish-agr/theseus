"""Golden end-to-end fixture: the mini scenario (map a room with a
limited-FOV sensor, then guide to the target past a pacing person) must
arrive, never collide, and produce a byte-identical trace.

This freeze is deliberate: when the engine is ported to Swift (milestone
M1), the port replays the same scenario and must reproduce this hash.
If you change engine behavior on purpose, regenerate with
`python engine/scripts/generate.py` and commit the new hash + trace."""

from pathlib import Path

from theseus_engine.demo import run_mini

GOLDEN = Path(__file__).resolve().parents[2] / "fixtures" / "golden" / "mini.sha256"


def test_mini_scenario_arrives_safely_and_matches_golden():
    trace, summary = run_mini()
    assert summary["arrived"] is True
    assert summary["collisions"] == 0
    assert summary["replans"] >= 2            # the mover must actually matter
    assert summary["final_state"] == "ARRIVED"
    assert GOLDEN.exists(), \
        "golden hash missing — run: python engine/scripts/generate.py"
    assert trace.sha256() == GOLDEN.read_text().strip(), \
        "trace changed — if intentional, regenerate goldens and commit"
