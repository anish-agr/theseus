"""Golden fixture #3: walk mode. Free-roam with a person pacing the room
must keep moving (this is the 'longest unobstructed vector' feature from
the original spec) and touch nothing — the swept-body gate exists because
a thin VFH ray plus a stale clearance cache once grazed the mover."""

from pathlib import Path

from theseus_engine.demo import run_mini_walk

GOLDEN = Path(__file__).resolve().parents[2] / "fixtures" / "golden" / \
    "mini-walk.sha256"


def test_mini_walk_roams_safely_and_matches_golden():
    trace, summary = run_mini_walk()
    assert summary["collisions"] == 0
    assert summary["traveled_m"] >= 12.0      # actually roams (~0.4+ m/s avg)
    assert summary["blocked_ticks"] == 0      # never boxed in, in an open room
    assert summary["final_state"] == "IDLE"   # WALKING -> STOP -> IDLE
    assert GOLDEN.exists(), \
        "golden hash missing — run: python engine/scripts/generate.py"
    assert trace.sha256() == GOLDEN.read_text().strip(), \
        "trace changed — if intentional, regenerate goldens and commit"
