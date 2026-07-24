"""Lane D groundwork: dataset soundness, baseline floor, metric honesty.
A future UNet must beat the numbers pinned here on the SAME held-out
seeds, or it doesn't ship."""

from inpaint.baseline import inpaint_nearest, predict_all_free
from inpaint.dataset import generate_pair, unknown_indices
from inpaint.metrics import evaluate


def test_pairs_are_deterministic_and_consistent():
    a = generate_pair(3)
    b = generate_pair(3)
    assert a.partial == b.partial and a.full == b.full
    c = generate_pair(4)
    assert c.partial != a.partial
    # a partial map may be ignorant but must never LIE: every known cell
    # agrees with ground truth (the sim sensor is noiseless)
    for i, s in enumerate(a.partial):
        if s != 0:
            assert s == a.full[i]
    # and the glimpses actually revealed a useful amount of room
    assert 0.15 < a.known_fraction < 0.95
    assert len(unknown_indices(a)) > 100


def test_full_maps_have_no_unknown():
    p = generate_pair(1)
    assert all(s != 0 for s in p.full)


def test_nearest_fills_everything_reachable():
    p = generate_pair(2)
    pred = inpaint_nearest(p.partial, p.w, p.h)
    assert all(s != 0 for s in pred)          # every cell gets a verdict
    for i, s in enumerate(p.partial):          # known cells untouched
        if s != 0:
            assert pred[i] == s


def test_baseline_beats_the_all_free_strawman():
    seeds = range(6)
    near = evaluate(inpaint_nearest, seeds)
    free = evaluate(predict_all_free, seeds)
    # the honest metric: all-free hallucinates away every wall
    assert free.iou_occupied == 0.0
    assert near.iou_occupied > 0.30
    assert near.accuracy > free.accuracy + 0.05
    # pinned floor for the future UNet (same seeds, must beat BOTH):
    assert near.accuracy > 0.70
