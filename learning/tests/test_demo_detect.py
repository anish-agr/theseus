"""Integration test for the detection-waypoint lane: the synthetic
detector's noisy pixels, projected through the real geometry and merged
by the real registry, must converge to every true object and promote
none of the injected ghosts."""

from theseus_engine.geometry import dist

from demo_detect import OBJECTS, run


def test_all_objects_recovered_accurately_and_no_ghost_promoted():
    reg, stats = run(seed=0)
    for label, truth in OBJECTS:
        wp = reg.target_for(label)
        assert wp is not None, f"{label} was not recovered"
        assert dist(wp.pos, truth) < 0.25, f"{label} localized poorly"
    # ghosts are single low-confidence hits: never promoted, never targets
    assert all(w.label != "ghost" for w in reg.targets())
    assert stats["false_positives_injected"] >= 1  # the test actually tried


def test_recovery_is_stable_across_seeds():
    for seed in range(4):
        reg, _ = run(seed=seed)
        labels = {w.label for w in reg.targets()}
        assert {"fridge", "chair", "table"} <= labels
        assert "ghost" not in labels
