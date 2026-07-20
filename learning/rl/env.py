"""NavEnv — a Gymnasium-style steering environment over the engine sim.

The agent learns the SAME job steering.VFHSteering does: given a local
view and a goal direction, choose a heading and speed that make safe
progress. That parity is deliberate — a trained policy exports to Core
ML and drops behind steering.SteeringPolicy for a live A/B against the
classical controller (roadmap M5).

Design choices worth knowing:

- Observation is EGOCENTRIC (rotated into the agent's frame): a KxK
  occupancy crop looking forward, plus the goal as (sin, cos) of the
  bearing error, normalized remaining distance, and last speed. Ego
  framing gives translation+rotation invariance, so the policy
  generalizes across rooms instead of memorizing coordinates.
- Reward uses POTENTIAL-BASED shaping (Ng et al. 1999) on the flow-field
  geodesic distance to the goal. Potential-based shaping provably leaves
  the optimal policy unchanged while making the reward dense — the agent
  gets a gradient every step instead of a sparse arrival bonus. The
  field is the exact same solver evacuation mode uses (flowfield.py).
- Kinematics, turn-rate limits and collision checks are the tested
  Simulator, not a reimplementation. Movers move; the crop sees them.

gymnasium is optional: if installed, NavEnv IS a gym.Env with proper
spaces; if not, the identical class works standalone (reset/step) for
tests and scripted controllers.
"""

from __future__ import annotations

import math

from theseus_engine.flowfield import FlowField
from theseus_engine.geometry import bearing, dist, polyline_length, wrap_angle
from theseus_engine.grid import PlanParams
from theseus_engine.sim import Simulator

from .rooms import make_room

try:  # optional dependency
    import gymnasium as gym
    from gymnasium import spaces
    import numpy as np
    _HAS_GYM = True
    _Base = gym.Env
except Exception:  # pragma: no cover - exercised only without gym installed
    _HAS_GYM = False
    _Base = object

# (delta-heading in radians, speed in m/s) — relative turns, so the
# policy is heading-invariant. Turn-rate limiting is enforced by the sim.
ACTIONS: list[tuple[float, float]] = [
    (dh, v)
    for v in (0.5, 0.9)
    for dh in (-0.6, -0.3, 0.0, 0.3, 0.6)
]


class NavEnv(_Base):
    metadata = {"render_modes": []}

    def __init__(self, difficulty: dict | None = None, *, seed: int = 0,
                 ego_k: int = 15, ego_res: float = 0.12, max_steps: int = 400,
                 arrive_m: float = 0.4, params: PlanParams | None = None):
        super().__init__()
        self.difficulty = difficulty or {"n_obstacles": 4, "n_movers": 0}
        self.ego_k = ego_k
        self.ego_res = ego_res
        self.max_steps = max_steps
        self.arrive_m = arrive_m
        self.params = params or PlanParams(radius=0.28, safe_margin=0.5,
                                           margin_weight=1.2)
        self._seed = seed
        self.obs_dim = ego_k * ego_k + 4
        if _HAS_GYM:
            self.action_space = spaces.Discrete(len(ACTIONS))
            self.observation_space = spaces.Box(low=-1.0, high=1.0,
                                                shape=(self.obs_dim,),
                                                dtype=np.float32)
        self.sim: Simulator | None = None

    # ---- gym API ---------------------------------------------------------

    def reset(self, *, seed: int | None = None, options=None):
        if seed is not None:
            self._seed = seed
        # regenerate until the goal is reachable from the start
        for attempt in range(50):
            room, goal = make_room(self._seed + attempt * 100003,
                                   cell=0.05, **self.difficulty)
            sim = Simulator(room, self.params, sensor_range=0.1)
            goal_cell = sim.truth.world_to_cell(goal)
            ff = FlowField.build(sim.truth, [goal_cell], self.params)
            start_cell = sim.truth.world_to_cell((room["start"][0],
                                                  room["start"][1]))
            if ff.distance(start_cell) < float("inf"):
                break
        else:  # pragma: no cover - make_room is reliably solvable
            raise RuntimeError("could not generate a solvable room")
        self.sim = sim
        self.goal = goal
        self.ff = ff
        # d0: geodesic COST (used to normalize the reward's progress term).
        self.d0 = max(1e-3, ff.distance(start_cell))
        # opt_len: geometric length of the optimal route in meters — the
        # honest SPL denominator (cost != distance once margins bend it).
        route = ff.route_from(start_cell)
        self.opt_len = (polyline_length([sim.truth.cell_center(c)
                                         for c in route.cells])
                        if route else self.d0)
        self.steps = 0
        self.prev_speed = 0.0
        self._prev_d = self._geo_dist()
        obs = self._obs()
        return (obs, {}) if _HAS_GYM else (obs, {})

    def step(self, action: int):
        assert self.sim is not None, "call reset() first"
        dh, speed = ACTIONS[int(action)]
        self.sim.advance()                       # movers act first
        heading_cmd = self.sim.pose[2] + dh
        collided = self.sim.step_motion(heading_cmd, speed)
        self.steps += 1

        d = self._geo_dist()
        # potential-based shaping: dense progress signal, optimum-preserving
        reward = 5.0 * (self._prev_d - d)
        reward -= 0.01                            # time pressure
        reward -= 0.03 * abs(dh) / 0.6            # penalize jerky turns
        if collided:
            reward -= 0.5                         # bumped a wall/obstacle
        self._prev_d = d
        self.prev_speed = 0.0 if collided else speed

        arrived = dist(self._pos(), self.goal) < self.arrive_m
        terminated = bool(arrived)
        truncated = self.steps >= self.max_steps
        if arrived:
            reward += 10.0
        info = {"arrived": arrived, "collided": collided,
                "geo_dist": d, "steps": self.steps}
        obs = self._obs()
        if _HAS_GYM:
            return obs, float(reward), terminated, truncated, info
        return obs, float(reward), terminated, truncated, info

    # ---- internals -------------------------------------------------------

    def _pos(self):
        return (self.sim.pose[0], self.sim.pose[1])

    def _geo_dist(self) -> float:
        d = self.ff.distance(self.sim.truth.world_to_cell(self._pos()))
        return self.d0 if d == float("inf") else d

    def _obs(self):
        x, y, th = self.sim.pose
        ch, sh = math.cos(th), math.sin(th)
        half = self.ego_k // 2
        crop = [0.0] * (self.ego_k * self.ego_k)
        k = 0
        for j in range(self.ego_k):           # forward axis (j-half ahead)
            fwd = (j - half) * self.ego_res
            for i in range(self.ego_k):        # lateral axis (left positive)
                lat = (i - half) * self.ego_res
                wx = x + ch * fwd - sh * lat
                wy = y + sh * fwd + ch * lat
                blocked, _ = self.sim.truth_blocked(
                    self.sim.truth.world_to_cell((wx, wy)))
                crop[k] = 1.0 if blocked else 0.0
                k += 1
        berr = wrap_angle(bearing(self._pos(), self.goal) - th)
        tail = [math.sin(berr), math.cos(berr),
                max(-1.0, min(1.0, self._geo_dist() / self.d0)),
                self.prev_speed / 0.9]
        vec = crop + tail
        if _HAS_GYM:
            return np.asarray(vec, dtype=np.float32)
        return vec


def greedy_policy(env: "NavEnv", obs) -> int:
    """A dependency-free reactive baseline (VFH-lite on the ego crop):
    for each candidate turn, march a ray through the occupancy crop to
    measure how far it is clear, then pick the turn that best trades
    open space against goal alignment. Not learned — it exists to prove
    the env is solvable and its rewards point the right way, and to give
    a trained policy something concrete to beat."""
    k = env.ego_k
    half = k // 2
    res = env.ego_res
    sin_b, cos_b = obs[k * k], obs[k * k + 1]
    berr = math.atan2(sin_b, cos_b)

    body = max(1, round(env.params.radius / res))   # sweep the body width

    def free_dist(dh: float) -> float:
        """Clear distance (m) along relative heading dh in the ego crop,
        swept over the agent's body width so a thin ray can't thread a
        gap the fat body won't fit. Crop axes: +j forward, +i left;
        +dh turns left (project convention)."""
        cd, sd = math.cos(dh), math.sin(dh)
        for s in range(1, half + 1):
            for p in range(-body, body + 1):         # perpendicular band
                jj = half + round(s * cd - p * sd)
                ii = half + round(s * sd + p * cd)
                if not (0 <= jj < k and 0 <= ii < k):
                    continue                          # off-crop reads open
                if obs[jj * k + ii] > 0.5:
                    return (s - 1) * res
        return half * res

    deltas = sorted({dh for dh, _ in ACTIONS})
    # maximize clearance, tie-broken toward the goal bearing
    best_dh = max(deltas, key=lambda dh: (2.0 * free_dist(dh)
                                          - abs(wrap_angle(dh - berr))))
    speed = 0.9 if free_dist(best_dh) > 0.6 else 0.5
    return ACTIONS.index((best_dh, speed))
