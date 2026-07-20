"""The evaluation harness itself must be trustworthy before it can judge
a policy. These tests pin SPL's definition and the baseline's floor."""

import pytest

from rl.env import NavEnv, greedy_policy
from rl.evaluate import Episode, evaluate, run_episode
from rl.rooms import CURRICULUM


def test_spl_definition():
    assert Episode(True, 10, 5.0, 5.0).spl == pytest.approx(1.0)
    assert Episode(True, 10, 10.0, 5.0).spl == pytest.approx(0.5)  # 2x detour
    assert Episode(False, 10, 5.0, 5.0).spl == 0.0                 # no success


def test_empty_room_is_near_optimal():
    m = evaluate(greedy_policy, CURRICULUM["empty"], range(6), max_steps=300)
    assert m.success_rate == 1.0
    assert m.spl > 0.6            # straight shots should be efficient


def test_baseline_has_a_sane_floor_on_static_clutter():
    m = evaluate(greedy_policy, CURRICULUM["static"], range(10))
    assert m.n == 10
    assert m.success_rate >= 0.6  # the number a trained policy must beat
    assert 0.0 < m.spl <= 1.0


def test_single_episode_records_geometry():
    env = NavEnv(CURRICULUM["empty"], seed=1, max_steps=300)
    ep = run_episode(env, greedy_policy)
    assert ep.success is True
    assert ep.opt_len > 0.0
    assert ep.path_len > 0.0
    assert 0.0 < ep.spl <= 1.0                 # arrival radius caps it at 1
    assert ep.steps > 0
