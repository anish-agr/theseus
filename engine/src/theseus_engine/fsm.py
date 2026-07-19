"""Navigation state machine.

One explicit transition table instead of booleans scattered across
callbacks — on-device, ARKit delegate callbacks, the planner actor and
the UI will all poke at navigation state concurrently, and "which mode
are we actually in" must have exactly one answer. Illegal transitions
raise instead of being silently ignored: in testing that surfaces logic
bugs immediately, and the controller can always ask `can(event)` first.

TRACKING_LOST is special-cased: it may fire from ANY active state (ARKit
can lose tracking at any moment), parks the machine in RELOCALIZING and
remembers where it was, so TRACKING_RECOVERED resumes seamlessly.
"""

from __future__ import annotations

from enum import Enum


class State(Enum):
    IDLE = "IDLE"
    MAPPING = "MAPPING"            # user sweeps the space; optimistic planning allowed
    PLANNING = "PLANNING"          # a route is being (re)computed
    GUIDING = "GUIDING"            # following cues toward a goal (Ariadne mode)
    WALKING = "WALKING"            # free-roam steering, no destination (walk mode)
    BLOCKED = "BLOCKED"            # no route exists right now; waiting / retrying
    ARRIVED = "ARRIVED"
    RELOCALIZING = "RELOCALIZING"  # tracking lost; world frame unreliable


class Event(Enum):
    SCAN_STARTED = "SCAN_STARTED"
    MAP_READY = "MAP_READY"
    GOAL_SET = "GOAL_SET"
    PLAN_READY = "PLAN_READY"
    PLAN_FAILED = "PLAN_FAILED"
    ROUTE_BLOCKED = "ROUTE_BLOCKED"    # current path invalidated by new observations
    OFF_ROUTE = "OFF_ROUTE"            # guided human left the corridor
    ARRIVED_EVT = "ARRIVED_EVT"
    WALK_TOGGLED = "WALK_TOGGLED"
    RETRY = "RETRY"
    STOP = "STOP"
    TRACKING_LOST = "TRACKING_LOST"
    TRACKING_RECOVERED = "TRACKING_RECOVERED"


class IllegalTransition(Exception):
    def __init__(self, state: State, event: Event):
        super().__init__(f"event {event.value} is illegal in state {state.value}")
        self.state = state
        self.event = event


_TABLE: dict[tuple[State, Event], State] = {
    (State.IDLE, Event.SCAN_STARTED): State.MAPPING,
    (State.IDLE, Event.GOAL_SET): State.PLANNING,
    (State.IDLE, Event.WALK_TOGGLED): State.WALKING,

    (State.MAPPING, Event.MAP_READY): State.IDLE,
    (State.MAPPING, Event.GOAL_SET): State.PLANNING,
    (State.MAPPING, Event.STOP): State.IDLE,

    (State.PLANNING, Event.PLAN_READY): State.GUIDING,
    (State.PLANNING, Event.PLAN_FAILED): State.BLOCKED,
    (State.PLANNING, Event.STOP): State.IDLE,

    (State.GUIDING, Event.ROUTE_BLOCKED): State.PLANNING,
    (State.GUIDING, Event.OFF_ROUTE): State.PLANNING,
    (State.GUIDING, Event.GOAL_SET): State.PLANNING,
    (State.GUIDING, Event.ARRIVED_EVT): State.ARRIVED,
    (State.GUIDING, Event.WALK_TOGGLED): State.WALKING,
    (State.GUIDING, Event.STOP): State.IDLE,

    (State.WALKING, Event.WALK_TOGGLED): State.IDLE,
    (State.WALKING, Event.GOAL_SET): State.PLANNING,
    (State.WALKING, Event.ROUTE_BLOCKED): State.BLOCKED,
    (State.WALKING, Event.STOP): State.IDLE,

    (State.BLOCKED, Event.RETRY): State.PLANNING,
    (State.BLOCKED, Event.PLAN_READY): State.GUIDING,
    (State.BLOCKED, Event.GOAL_SET): State.PLANNING,
    (State.BLOCKED, Event.STOP): State.IDLE,

    (State.ARRIVED, Event.GOAL_SET): State.PLANNING,
    (State.ARRIVED, Event.WALK_TOGGLED): State.WALKING,
    (State.ARRIVED, Event.STOP): State.IDLE,
}


class StateMachine:
    def __init__(self, initial: State = State.IDLE):
        self.state = initial
        self._resume: State | None = None
        self.history: list[tuple[State, Event, State]] = []

    def can(self, event: Event) -> bool:
        if event == Event.TRACKING_LOST:
            return self.state not in (State.IDLE, State.RELOCALIZING)
        if event == Event.TRACKING_RECOVERED:
            return self.state == State.RELOCALIZING
        return (self.state, event) in _TABLE

    def step(self, event: Event) -> State:
        old = self.state
        if event == Event.TRACKING_LOST:
            if not self.can(event):
                raise IllegalTransition(old, event)
            self._resume = old
            self.state = State.RELOCALIZING
        elif event == Event.TRACKING_RECOVERED:
            if not self.can(event):
                raise IllegalTransition(old, event)
            self.state = self._resume or State.IDLE
            self._resume = None
        else:
            nxt = _TABLE.get((old, event))
            if nxt is None:
                raise IllegalTransition(old, event)
            self.state = nxt
        self.history.append((old, event, self.state))
        return self.state
