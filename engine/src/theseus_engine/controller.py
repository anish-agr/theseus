"""NavController: wires perception, world model, planners, steering,
guidance and the FSM into a per-tick loop.

On iOS this file becomes the actor pipeline (perception actor -> world
model actor -> planner actor -> guidance/steering at cue rate) described
in docs/ARCHITECTURE.md; the logic and the order of operations per tick
are meant to survive that translation:

  advance world -> sense -> notify planner of changes -> validate current
  path -> (replan incrementally if needed, via the FSM) -> compute cue ->
  steer -> move -> emit trace frame.

Mapping uses optimistic planning (unknown is traversable) with periodic
full A* — you are allowed to *plan into* space you haven't seen while
building the map. Guidance is pessimistic (unknown is a wall) and leans
on D* Lite so mid-route world changes cost milliseconds, not a rebuild.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, replace

from . import astar, frontier
from .dstar_lite import DStarLite
from .fsm import Event, State, StateMachine
from .geometry import Cell, Vec, bearing, dist, wrap_angle
from .grid import OCCUPIED, PlanParams
from .guidance import ARRIVE, OFF_ROUTE, GuidanceFollower
from .sim import Simulator
from .steering import VFHSteering
from .trace import TraceWriter


@dataclass
class ControllerConfig:
    map_replan_every: int = 40      # ticks between scheduled mapping replans
    clearance_every: int = 5        # ticks between clearance refreshes
    wp_arrive: float = 0.5          # m: "reached this scan waypoint"
    blocked_wait: int = 15          # ticks to wait in BLOCKED before RETRY
    blocked_steer_limit: int = 8    # consecutive boxed-in ticks -> force replan
    guidance_lookahead: float = 0.9
    pivot_thresh: float = 0.45      # rad: heading error above this -> turn in place


class NavController:
    def __init__(self, sim: Simulator, params: PlanParams,
                 trace: TraceWriter | None = None,
                 config: ControllerConfig | None = None):
        self.sim = sim
        self.params = params
        self.opt_params = replace(params, unknown_ok=True)
        self.cfg = config or ControllerConfig()
        self.fsm = StateMachine()
        self.trace = trace
        self.steer_guide = VFHSteering(params)
        self.steer_map = VFHSteering(self.opt_params)
        self.replans = 0
        self.frames = 0

    # ---- helpers ---------------------------------------------------------

    def _pos(self) -> Vec:
        return (self.sim.pose[0], self.sim.pose[1])

    def _cell(self) -> Cell:
        return self.sim.est.world_to_cell(self._pos())

    def _tick_world(self) -> list[Cell]:
        self.sim.advance()
        changed = self.sim.sense()
        if self.sim.tick % self.cfg.clearance_every == 0:
            self.sim.est.refresh_clearance()
        return changed

    def _emit(self, changed, cue=None, steer=None, events=(),
              path=None, smoothed=None, replan_ms=None) -> None:
        if self.trace is None:
            return
        x, y, th = self.sim.pose
        frame = {
            "t": round(self.sim.tick * self.sim.dt, 3),
            "pose": [x, y, th],
            "state": self.fsm.state.value,
            "occ": [[c[0], c[1], self.sim.est.state(c)] for c in changed],
            "movers": self.sim.mover_positions(),
        }
        if cue is not None:
            frame["cue"] = {"kind": cue.kind, "dist": cue.distance,
                            "deg": cue.angle_deg, "ct": cue.cross_track,
                            "corridor": cue.corridor,
                            "target": [cue.target[0], cue.target[1]]}
        if steer is not None:
            frame["steer"] = {"h": steer.heading, "v": steer.speed,
                              "free": steer.free_dist,
                              "blocked": steer.blocked}
        if events:
            frame["events"] = list(events)
        if path is not None:
            frame["path"] = [[c[0], c[1]] for c in path]
        if smoothed is not None:
            frame["smoothed"] = [[p[0], p[1]] for p in smoothed]
        if replan_ms is not None:
            frame["replan_ms"] = replan_ms
        self.trace.frame(**frame)
        self.frames += 1

    def _move(self, steer) -> None:
        """Steering validated free space along steer.heading — not along
        directions passed through while rotating. So: large heading error
        means pivot in place first, advance only once roughly aligned."""
        if steer.blocked:
            self.sim.step_motion(self.sim.pose[2], 0.0)
            return
        err = abs(wrap_angle(steer.heading - self.sim.pose[2]))
        speed = 0.0 if err > self.cfg.pivot_thresh else steer.speed
        self.sim.step_motion(steer.heading, speed)

    @staticmethod
    def _remaining(cells: list[Cell], ptr: int, here: Cell) -> int:
        """Advance a monotone pointer to the path cell nearest the agent
        (looking a bounded window ahead), so validity checks only consider
        the part of the path still to be walked."""
        best_i, best_d = ptr, None
        for i in range(ptr, min(ptr + 12, len(cells))):
            d = abs(cells[i][0] - here[0]) + abs(cells[i][1] - here[1])
            if best_d is None or d < best_d:
                best_i, best_d = i, d
        return best_i

    # ---- mapping phase -----------------------------------------------------

    def run_mapping(self, scan_pts: list[Vec], laps: int = 2,
                    per_wp: int = 350, done_check=None) -> bool:
        """Walk the scan waypoints (optimistically planned) to build the
        map, like a user sweeping their phone around a room. Stops early
        if done_check() says the map is good enough."""
        est = self.sim.est
        self.fsm.step(Event.SCAN_STARTED)
        for _lap in range(laps):
            for wp in scan_pts:
                self._goto_optimistic(tuple(wp), per_wp)
            est.refresh_clearance(force=True)
            if done_check is not None and done_check():
                break
        self.fsm.step(Event.MAP_READY)
        return True

    def _goto_optimistic(self, wp: Vec, max_ticks: int) -> bool:
        est = self.sim.est
        follower = None
        cells: list[Cell] | None = None
        ptr = 0
        age = 10 ** 9
        for _ in range(max_ticks):
            changed = self._tick_world()
            if dist(self._pos(), wp) < self.cfg.wp_arrive:
                self._emit(changed)
                return True
            age += 1
            need = (cells is None or age >= self.cfg.map_replan_every
                    or not astar.path_valid(est, cells[ptr:], self.opt_params))
            events = []
            replan_ms = None
            path_field = smoothed_field = None
            if need:
                est.refresh_clearance()
                t0 = time.perf_counter()
                res = astar.plan(est, self._cell(), est.world_to_cell(wp),
                                 self.opt_params)
                replan_ms = (time.perf_counter() - t0) * 1000.0
                self.replans += 1
                age = 0
                if res is None:
                    self._emit(changed, events=["WP_UNREACHABLE"],
                               replan_ms=replan_ms)
                    return False  # try again next lap
                cells, ptr = res.cells, 0
                smoothed = astar.smooth(est, cells, self.opt_params)
                follower = GuidanceFollower(smoothed,
                                            lookahead=self.cfg.guidance_lookahead)
                events.append("PLANNED")
                path_field, smoothed_field = cells, smoothed
            ptr = self._remaining(cells, ptr, self._cell())
            cue = follower.cue(est, self.sim.pose)
            if cue.kind == ARRIVE:
                self._emit(changed, cue=cue, events=events)
                return True
            steer = self.steer_map.decide(est, self.sim.pose,
                                          bearing(self._pos(), cue.target))
            self._move(steer)
            if cue.kind == OFF_ROUTE:
                age = 10 ** 9  # force replan next tick from wherever we are
            self._emit(changed, cue=cue, steer=steer, events=events,
                       path=path_field, smoothed=smoothed_field,
                       replan_ms=replan_ms)
        return False

    # ---- explore phase (virtual-agent auto-mapping) ------------------------

    def run_explore(self, max_targets: int = 60, per_target: int = 400,
                    min_cluster: int = 4) -> dict:
        """Frontier-driven auto-mapping: walk to the nearest frontier
        cluster until none remain. Target ranking is pessimistic (only
        chase frontiers reachable through known space); motion reuses the
        optimistic mapping primitive — mapping-mode semantics, same as a
        user sweeping their phone, just self-directed."""
        est = self.sim.est
        self.fsm.step(Event.SCAN_STARTED)
        changed = self._tick_world()          # open our eyes before asking
        est.refresh_clearance(force=True)     # "is there anything to see?"
        self._emit(changed, events=["EXPLORE_STARTED"])
        visited = 0
        failures = 0
        while visited < max_targets:
            est.refresh_clearance(force=True)
            tgt = frontier.select_target(est, self._cell(), self.params,
                                         min_cluster=min_cluster,
                                         min_dist_m=self.cfg.wp_arrive + 0.25)
            if tgt is None:
                break
            visited += 1
            if self._goto_optimistic(est.cell_center(tgt.cell), per_target):
                failures = 0
            else:
                failures += 1
                if failures >= 3:
                    break  # the remaining clusters keep defeating us; stop
        self.fsm.step(Event.MAP_READY)
        return {"targets": visited, "failures": failures}

    # ---- walk mode (free roam, no destination) ------------------------------

    def run_walk(self, ticks: int) -> dict:
        """Walk mode: no destination — keep moving through free space,
        reacting to whatever the sensor sees. This is the original
        "longest unobstructed forward vector" idea made stable: VFH picks
        the most open sector and hysteresis keeps the choice from
        flickering. Uses mapping-mode optimism (unknown space ahead is
        walkable until the continuously-running sensor objects) because
        reactive avoidance is the sensor's job here, not the map's."""
        self.fsm.step(Event.WALK_TOGGLED)
        traveled = 0.0
        blocked_ticks = 0
        for _ in range(ticks):
            changed = self._tick_world()
            before = self._pos()
            steer = self.steer_map.decide(self.sim.est, self.sim.pose, None)
            # Two safety gates before advancing, both walk-mode-specific:
            # (1) don't outrun the sensor — if the ground along the chosen
            #     heading wasn't SEEN recently, pivot first so the FOV
            #     sweeps it (a mover may have wandered into stale space);
            # (2) swept-body check against LIVE cell states — VFH's thin
            #     ray can miss a body-width graze, and the clearance field
            #     it leans on is cached (refreshed every few ticks), which
            #     is exactly long enough for a walking person to shift one
            #     body width. Check actual occupied cells, not the cache.
            if not steer.blocked and (not self._front_fresh(steer.heading)
                                      or not self._swept_clear(steer.heading)):
                steer = replace(steer, speed=0.0, reason="hold_safe")
            self._move(steer)
            traveled += dist(before, self._pos())
            blocked_ticks += int(steer.blocked)
            self._emit(changed, steer=steer)
        self.fsm.step(Event.STOP)
        return {"traveled_m": round(traveled, 2),
                "blocked_ticks": blocked_ticks}

    def _swept_clear(self, heading: float, advance_m: float = 0.3,
                     pad: float = -0.02) -> bool:
        """True if the body-swept corridor along `heading` has no
        OCCUPIED cell INSIDE the legal clearance minimum, judged on
        current cell states (which update every sense) instead of the
        cached clearance field (which does not). The gate radius sits
        just UNDER the body radius on purpose: skimming a wall at the
        cost model's legal 0.28 m is allowed; a person's cells intruding
        deep into the corridor — the thing the stale cache misses — is
        not. A wider radius here re-vetoes legal passages and the walker
        stalls (measured: 264/350 ticks held at +0.03 pad)."""
        est = self.sim.est
        x, y, _ = self.sim.pose
        r = self.params.radius + pad
        span = int(r / est.cell_size) + 1
        ca, sa = math.cos(heading), math.sin(heading)
        step = est.cell_size
        d = step
        while d <= advance_m:
            px, py = x + ca * d, y + sa * d
            pc = est.world_to_cell((px, py))
            for dy in range(-span, span + 1):
                for dx in range(-span, span + 1):
                    c = (pc[0] + dx, pc[1] + dy)
                    if (est.in_bounds(c) and est.state(c) == OCCUPIED
                            and dist(est.cell_center(c), (px, py)) <= r):
                        return False
            d += step
        return True

    def _front_fresh(self, heading: float, dist_m: float = 0.5,
                     max_age: int = 8) -> bool:
        """True if every cell within dist_m along `heading` was observed
        within the last max_age ticks."""
        est = self.sim.est
        x, y, _ = self.sim.pose
        ca, sa = math.cos(heading), math.sin(heading)
        steps = max(1, int(dist_m / est.cell_size))
        for i in range(1, steps + 1):
            d = i * est.cell_size
            c = est.world_to_cell((x + ca * d, y + sa * d))
            if not est.in_bounds(c):
                return True          # the boundary is a wall, not a mover
            if self.sim.tick - est.last_seen[est.idx(c)] > max_age:
                return False
        return True

    # ---- guidance phase ("Ariadne mode") -----------------------------------

    def run_guidance(self, goal: Vec, max_ticks: int = 2500) -> bool:
        """Guide toward `goal` with incremental replanning. Returns True
        on arrival."""
        est = self.sim.est
        est.refresh_clearance(force=True)
        goal_cell = est.world_to_cell(goal)
        self.fsm.step(Event.GOAL_SET)

        ds = DStarLite(est, self._cell(), goal_cell, self.params)
        follower: GuidanceFollower | None = None
        cells: list[Cell] | None = None
        ptr = 0
        boxed = 0
        wait = 0

        def replan(events: list[str]) -> tuple[list[Cell] | None, float]:
            nonlocal follower, ptr
            est.refresh_clearance()
            t0 = time.perf_counter()
            res = ds.plan()
            ms = (time.perf_counter() - t0) * 1000.0
            self.replans += 1
            if res is None:
                if self.fsm.state != State.BLOCKED:
                    self.fsm.step(Event.PLAN_FAILED)
                events.append("PLAN_FAILED")
                return None, ms
            smoothed = astar.smooth(est, res.cells, self.params)
            follower = GuidanceFollower(smoothed,
                                        lookahead=self.cfg.guidance_lookahead)
            ptr = 0
            self.fsm.step(Event.PLAN_READY)
            events.append("REROUTED")
            return res.cells, ms

        events: list[str] = []
        cells, ms = replan(events)
        self._emit([], events=events, path=cells,
                   smoothed=follower.path if follower else None, replan_ms=ms)

        for _ in range(max_ticks):
            changed = self._tick_world()
            if changed:
                ds.notify_changed(changed)
            here = self._cell()
            if here != ds.start:
                ds.update_start(here)

            events = []
            replan_ms = None
            path_field = smoothed_field = None

            if self.fsm.state == State.BLOCKED:
                wait += 1
                if wait >= self.cfg.blocked_wait:
                    wait = 0
                    self.fsm.step(Event.RETRY)   # BLOCKED -> PLANNING
                    cells, replan_ms = replan(events)
                    path_field = cells
                    smoothed_field = follower.path if cells else None
                self._emit(changed, events=events, path=path_field,
                           smoothed=smoothed_field, replan_ms=replan_ms)
                continue

            ptr = self._remaining(cells, ptr, here)
            if not astar.path_valid(est, cells[ptr:], self.params):
                self.fsm.step(Event.ROUTE_BLOCKED)   # GUIDING -> PLANNING
                cells, replan_ms = replan(events)
                path_field = cells
                smoothed_field = follower.path if cells else None
                if cells is None:
                    self._emit(changed, events=events, replan_ms=replan_ms)
                    continue

            cue = follower.cue(est, self.sim.pose)
            if cue.kind == ARRIVE:
                self.fsm.step(Event.ARRIVED_EVT)
                self._emit(changed, cue=cue, events=events + ["ARRIVED"],
                           path=path_field, smoothed=smoothed_field,
                           replan_ms=replan_ms)
                return True
            if cue.kind == OFF_ROUTE:
                self.fsm.step(Event.OFF_ROUTE)      # GUIDING -> PLANNING
                cells, replan_ms = replan(events)
                path_field = cells
                smoothed_field = follower.path if cells else None
                if cells is None:
                    self._emit(changed, events=events, replan_ms=replan_ms)
                    continue
                cue = follower.cue(est, self.sim.pose)

            steer = self.steer_guide.decide(est, self.sim.pose,
                                            bearing(self._pos(), cue.target))
            if steer.blocked:
                boxed += 1
                if boxed >= self.cfg.blocked_steer_limit:
                    boxed = 0
                    self.fsm.step(Event.ROUTE_BLOCKED)
                    cells, replan_ms = replan(events)
                    path_field = cells
                    smoothed_field = follower.path if cells else None
            else:
                boxed = 0
            self._move(steer)
            self._emit(changed, cue=cue, steer=steer, events=events,
                       path=path_field, smoothed=smoothed_field,
                       replan_ms=replan_ms)
        return False
