"""Reactive local steering ("walk mode") — VFH-flavored sector scoring.

Global planners answer "which route"; steering answers "which way do I
nudge RIGHT NOW", at sensor rate, without a graph search. The classic
family here is the Vector Field Histogram (Borenstein & Koren, 1991):
discretize headings into sectors, measure free distance per sector, score
and pick. Two details matter enormously in practice and are encoded here:

- hysteresis: without a bonus for the previous choice plus a minimum
  commit time, tiny occupancy changes flip the winner every tick and the
  agent (or the haptic cue driving a human) oscillates;
- an explicit BLOCKED outcome instead of "least bad" flailing, so the
  state machine can escalate to a replan.

This module deliberately exposes a tiny interface (SteeringPolicy) —
milestone M5 swaps in a learned policy (PPO -> Core ML) behind the same
signature and A/Bs it against this one.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Protocol

from .geometry import Vec, wrap_angle
from .grid import OccupancyGrid, PlanParams


@dataclass
class SteeringDecision:
    heading: float          # absolute commanded heading (rad)
    speed: float            # commanded speed (m/s)
    free_dist: float        # free distance along chosen heading (m)
    blocked: bool           # True: no admissible sector, stop and escalate
    reason: str


class SteeringPolicy(Protocol):
    def decide(self, grid: OccupancyGrid, pose: tuple[float, float, float],
               goal_bearing: float | None) -> SteeringDecision: ...


class VFHSteering:
    def __init__(self, params: PlanParams, n_sectors: int = 36,
                 lookahead: float = 2.5, min_free: float = 0.45,
                 w_free: float = 1.0, w_goal: float = 1.8,
                 w_keep: float = 0.35, w_prev: float = 0.45,
                 commit_ticks: int = 3, switch_margin: float = 0.25,
                 vmax: float = 1.0):
        self.params = params
        self.n = n_sectors
        self.lookahead = lookahead
        self.min_free = min_free
        self.w_free = w_free
        self.w_goal = w_goal
        self.w_keep = w_keep
        self.w_prev = w_prev
        self.commit_ticks = commit_ticks
        self.switch_margin = switch_margin
        self.vmax = vmax
        self._prev: float | None = None
        self._hold = 0

    def reset(self) -> None:
        self._prev = None
        self._hold = 0

    def ray_free(self, grid: OccupancyGrid, pos: Vec, ang: float) -> float:
        """March along `ang` and return meters of traversable space
        (capped at lookahead). Starts one cell out: the cell under the
        agent's own feet is a fact, not an option."""
        step = grid.cell_size * 0.5
        d = grid.cell_size
        ca, sa = math.cos(ang), math.sin(ang)
        while d <= self.lookahead:
            cell = grid.world_to_cell((pos[0] + ca * d, pos[1] + sa * d))
            if not grid.traversable(cell, self.params):
                return d - grid.cell_size * 0.5
            d += step
        return self.lookahead

    def decide(self, grid: OccupancyGrid, pose: tuple[float, float, float],
               goal_bearing: float | None = None) -> SteeringDecision:
        x, y, th = pose
        best_ang: float | None = None
        best_score = -math.inf
        best_free = 0.0
        prev_score = -math.inf
        prev_free = 0.0
        for k in range(self.n):
            ang = -math.pi + (k + 0.5) * (2.0 * math.pi / self.n)
            free = self.ray_free(grid, (x, y), ang)
            if free < self.min_free:
                continue
            score = self.w_free * (free / self.lookahead)
            score += self.w_keep * math.cos(wrap_angle(ang - th))
            if goal_bearing is not None:
                score += self.w_goal * math.cos(wrap_angle(ang - goal_bearing))
            if self._prev is not None:
                score += self.w_prev * math.cos(wrap_angle(ang - self._prev))
                if abs(wrap_angle(ang - self._prev)) < math.pi / self.n:
                    prev_score = score
                    prev_free = free
            if score > best_score:
                best_score = score
                best_ang = ang
                best_free = free
        if best_ang is None:
            self._prev = None
            self._hold = 0
            return SteeringDecision(th, 0.0, 0.0, True, "boxed_in")
        # hysteresis: during the commit window, keep the previous sector
        # unless the challenger wins by a clear margin
        if (self._hold > 0 and prev_score > -math.inf
                and best_score - prev_score < self.switch_margin):
            best_ang = self._prev
            best_free = prev_free
            self._hold -= 1
            reason = "hold"
        else:
            self._hold = self.commit_ticks
            reason = "steer"
        self._prev = best_ang
        frac = (best_free - self.min_free) / max(self.lookahead - self.min_free, 1e-6)
        speed = self.vmax * max(0.25, min(1.0, frac))
        return SteeringDecision(best_ang, speed, best_free, False, reason)
