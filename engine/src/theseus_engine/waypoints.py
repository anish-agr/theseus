"""Semantic waypoint registry: noisy detections in, stable named targets out.

The detection lane (learning/run_yolo.py offline now, a Vision/Core ML
provider at M4) emits proposals like ("fridge", (6.9, 4.4), conf 0.6) at
a few Hz. They jitter, drop out, and occasionally hallucinate. This
registry turns that stream into durable navigation targets with three
rules:

- MERGE:   a proposal within merge_radius of a same-label waypoint
           reinforces it; position is the confidence-weighted mean, so
           it converges to the object's true spot.
- PROMOTE: accumulated confidence >= promote_conf makes it a real,
           nameable destination ("go to the fridge"). Promotion has
           hysteresis: once promoted it stays usable while it lives.
- DECAY:   observe_area() reports "the detector looked here"; waypoints
           in view that were NOT re-sighted lose confidence and die at
           drop_conf. Objects move; maps must forget.

This is engine code (stdlib, ported to Swift at M1) because it runs
on-device — only the detector that FEEDS it lives in learning/.
"""

from __future__ import annotations

from dataclasses import dataclass

from .geometry import Vec, dist


@dataclass
class Waypoint:
    uid: str
    label: str
    pos: Vec
    confidence: float
    hits: int
    last_tick: int
    promoted: bool = False


class WaypointRegistry:
    def __init__(self, merge_radius: float = 0.7, promote_conf: float = 2.5,
                 drop_conf: float = 0.25, miss_decay: float = 0.6,
                 max_conf: float = 6.0):
        self.merge_radius = merge_radius
        self.promote_conf = promote_conf
        self.drop_conf = drop_conf
        self.miss_decay = miss_decay
        self.max_conf = max_conf
        self._wps: dict[str, Waypoint] = {}
        self._counter = 0

    def __len__(self) -> int:
        return len(self._wps)

    def get(self, uid: str) -> Waypoint | None:
        return self._wps.get(uid)

    def all(self) -> list[Waypoint]:
        return sorted(self._wps.values(), key=lambda w: w.uid)

    def report(self, label: str, pos: Vec, confidence: float = 1.0,
               tick: int = 0) -> Waypoint:
        """One detection hit. Returns the (possibly new) waypoint it
        merged into."""
        best: Waypoint | None = None
        for wp in self.all():
            if wp.label == label and dist(wp.pos, pos) <= self.merge_radius:
                if best is None or dist(wp.pos, pos) < dist(best.pos, pos):
                    best = wp
        if best is None:
            uid = f"{label}-{self._counter}"
            self._counter += 1
            best = Waypoint(uid, label, pos, 0.0, 0, tick)
            self._wps[uid] = best
        w_old, w_new = best.confidence, max(1e-6, confidence)
        tot = w_old + w_new
        best.pos = ((best.pos[0] * w_old + pos[0] * w_new) / tot,
                    (best.pos[1] * w_old + pos[1] * w_new) / tot)
        best.confidence = min(self.max_conf, best.confidence + confidence)
        best.hits += 1
        best.last_tick = tick
        if best.confidence >= self.promote_conf:
            best.promoted = True
        return best

    def observe_area(self, center: Vec, radius: float, tick: int,
                     seen_uids: frozenset[str] | set[str] = frozenset()) -> list[str]:
        """The detector processed a frame covering this area; call
        report() for its hits first, then pass those uids here. Every
        other waypoint inside the area decays. Returns uids removed."""
        dead: list[str] = []
        for uid, wp in self._wps.items():
            if uid in seen_uids or dist(wp.pos, center) > radius:
                continue
            wp.confidence -= self.miss_decay
            wp.last_tick = tick
            if wp.confidence < self.drop_conf:
                dead.append(uid)
        for uid in dead:
            del self._wps[uid]
        return dead

    def targets(self) -> list[Waypoint]:
        """Promoted waypoints, most confident first."""
        return sorted((w for w in self._wps.values() if w.promoted),
                      key=lambda w: (-w.confidence, w.uid))

    def target_for(self, label: str) -> Waypoint | None:
        """Best promoted waypoint with this label ("go to the fridge")."""
        for wp in self.targets():
            if wp.label == label:
                return wp
        return None
