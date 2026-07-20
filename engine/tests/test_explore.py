"""Golden end-to-end fixture #2: the frontier explorer must map the mini
room on its own — high known-floor fraction, zero collisions, and a
byte-identical trace (the Swift port replays this too)."""

from pathlib import Path

from theseus_engine.demo import run_mini_explore

GOLDEN = Path(__file__).resolve().parents[2] / "fixtures" / "golden" / \
    "mini-explore.sha256"


def test_mini_explore_maps_the_room_and_matches_golden():
    trace, summary = run_mini_explore()
    assert summary["collisions"] == 0
    assert summary["targets"] >= 2            # it actually chased frontiers
    assert summary["known_free_fraction"] >= 0.85
    assert summary["final_state"] == "IDLE"   # MAPPING -> MAP_READY -> IDLE
    assert GOLDEN.exists(), \
        "golden hash missing — run: python engine/scripts/generate.py"
    assert trace.sha256() == GOLDEN.read_text().strip(), \
        "trace changed — if intentional, regenerate goldens and commit"
