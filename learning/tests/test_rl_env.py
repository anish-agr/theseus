"""NavEnv contract tests — run without gymnasium/torch. They pin the
things a training run silently depends on: stable observation shape,
bounded values, optimum-preserving reward sign, and that the task is
actually solvable (a scripted greedy controller reaches the goal and
earns positive return). If these pass, a PPO run is debugging the policy,
not the environment."""

import math

import pytest

from rl.env import ACTIONS, NavEnv, greedy_policy
from rl.rooms import CURRICULUM, make_room


def rollout(env, policy, max_steps=400):
    obs, _ = env.reset()
    total = 0.0
    for _ in range(max_steps):
        a = policy(env, obs)
        obs, r, term, trunc, info = env.step(a)
        total += r
        if term or trunc:
            return total, info
    return total, {"arrived": False}


def test_observation_shape_and_bounds():
    env = NavEnv(CURRICULUM["static"], seed=1)
    obs, info = env.reset()
    assert len(obs) == env.obs_dim == env.ego_k * env.ego_k + 4
    assert all(-1.0001 <= v <= 1.0001 for v in obs)
    obs2, r, term, trunc, info = env.step(0)
    assert len(obs2) == env.obs_dim
    assert isinstance(r, float)
    assert term is False and trunc is False


def test_determinism_same_seed_same_room_and_obs():
    a, _ = NavEnv(CURRICULUM["clutter"], seed=7).reset()
    b, _ = NavEnv(CURRICULUM["clutter"], seed=7).reset()
    assert a == b
    # different seeds must generate different ROOMS (the start view can
    # coincide when both near-fields are open, so compare geometry)
    room7, _ = make_room(7, **CURRICULUM["clutter"])
    room8, _ = make_room(8, **CURRICULUM["clutter"])
    assert room7["rects"] != room8["rects"]


def test_greedy_solves_empty_room_with_positive_return():
    env = NavEnv(CURRICULUM["empty"], seed=3, max_steps=300)
    total, info = rollout(env, greedy_policy)
    assert info["arrived"] is True
    assert total > 0.0


def test_greedy_reaches_goal_across_seeds_with_static_clutter():
    arrived = 0
    for seed in range(8):
        env = NavEnv(CURRICULUM["static"], seed=seed, max_steps=400)
        _total, info = rollout(env, greedy_policy)
        arrived += int(info["arrived"])
    # greedy is a weak baseline (no real obstacle avoidance), but on
    # sparse static clutter it should still usually get there
    assert arrived >= 5


def test_progress_reward_sign_is_correct():
    env = NavEnv(CURRICULUM["empty"], seed=2)
    env.reset()
    # action bin for (straight, fast) points at the goal from start
    straight_fast = ACTIONS.index((0.0, 0.9))
    _obs, r, _t, _tr, _info = env.step(straight_fast)
    assert r > 0.0                       # moved toward the goal -> positive
    # turning 180-ish away should not beat going straight
    env2 = NavEnv(CURRICULUM["empty"], seed=2)
    env2.reset()
    away = ACTIONS.index((0.6, 0.9))
    _o2, r2, *_ = env2.step(away)
    assert r > r2


def test_reachability_guard_regenerates_walled_in_rooms():
    # a heavily cluttered room must still yield a solvable episode
    env = NavEnv({"n_obstacles": 9, "n_movers": 0}, seed=42)
    obs, _ = env.reset()
    assert env.d0 < float("inf")
    assert env.ff.distance(
        env.sim.truth.world_to_cell(env._pos())) < float("inf")


def test_movers_episode_runs():
    env = NavEnv(CURRICULUM["movers3"], seed=5, max_steps=120)
    total, info = rollout(env, greedy_policy)
    assert isinstance(total, float)
    assert "arrived" in info
