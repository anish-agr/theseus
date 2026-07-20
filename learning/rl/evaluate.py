"""Evaluation harness: success rate and SPL over held-out rooms.

SPL (Success weighted by Path Length; Anderson et al. 2018) is the
standard embodied-navigation metric — it rewards reaching the goal AND
doing it efficiently, so a policy that wanders can't hide behind a high
success rate. The optimal length is the flow-field geodesic the env
already computes, so SPL here is measured against the true shortest path,
not a straight-line lower bound.

This module has no ML dependencies: it evaluates ANY callable
policy(env, obs) -> action, so the scripted baseline and a trained
Core ML / PyTorch policy go through the identical measurement.
"""

from __future__ import annotations

from dataclasses import dataclass

from theseus_engine.geometry import dist

from .env import NavEnv


@dataclass
class Episode:
    success: bool
    steps: int
    path_len: float
    opt_len: float

    @property
    def spl(self) -> float:
        if not self.success:
            return 0.0
        return self.opt_len / max(self.opt_len, self.path_len, 1e-6)


def run_episode(env: NavEnv, policy, max_steps: int | None = None) -> Episode:
    obs, _ = env.reset()
    opt_len = env.opt_len
    prev = env._pos()
    path_len = 0.0
    limit = max_steps or env.max_steps
    for _ in range(limit):
        obs, _r, term, trunc, info = env.step(policy(env, obs))
        here = env._pos()
        path_len += dist(prev, here)
        prev = here
        if term or trunc:
            return Episode(bool(info["arrived"]), info["steps"], path_len,
                           opt_len)
    return Episode(False, limit, path_len, opt_len)


@dataclass
class Metrics:
    n: int
    success_rate: float
    spl: float
    mean_steps: float


def evaluate(policy, difficulty: dict, seeds, *, max_steps: int = 400,
             env_kwargs: dict | None = None) -> Metrics:
    """Aggregate metrics for a policy over a fixed set of seeds. Use a
    seed range disjoint from training for a real held-out measurement."""
    eps = []
    for s in seeds:
        env = NavEnv(difficulty, seed=s, max_steps=max_steps,
                     **(env_kwargs or {}))
        eps.append(run_episode(env, policy))
    n = len(eps)
    succ = sum(e.success for e in eps)
    return Metrics(
        n=n,
        success_rate=succ / n,
        spl=sum(e.spl for e in eps) / n,
        mean_steps=sum(e.steps for e in eps) / n,
    )
