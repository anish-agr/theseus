import pytest

from theseus_engine.fsm import Event, IllegalTransition, State, StateMachine


def test_happy_path_scan_then_guide():
    m = StateMachine()
    assert m.step(Event.SCAN_STARTED) == State.MAPPING
    assert m.step(Event.MAP_READY) == State.IDLE
    assert m.step(Event.GOAL_SET) == State.PLANNING
    assert m.step(Event.PLAN_READY) == State.GUIDING
    assert m.step(Event.ARRIVED_EVT) == State.ARRIVED


def test_replan_loop():
    m = StateMachine(State.GUIDING)
    assert m.step(Event.ROUTE_BLOCKED) == State.PLANNING
    assert m.step(Event.PLAN_FAILED) == State.BLOCKED
    assert m.step(Event.RETRY) == State.PLANNING
    assert m.step(Event.PLAN_READY) == State.GUIDING


def test_off_route_triggers_replan():
    m = StateMachine(State.GUIDING)
    assert m.step(Event.OFF_ROUTE) == State.PLANNING


def test_illegal_transition_raises():
    m = StateMachine()
    with pytest.raises(IllegalTransition):
        m.step(Event.PLAN_READY)
    assert m.state == State.IDLE               # unchanged after the raise


def test_tracking_loss_pauses_and_resumes_anywhere():
    m = StateMachine(State.GUIDING)
    assert m.step(Event.TRACKING_LOST) == State.RELOCALIZING
    assert m.step(Event.TRACKING_RECOVERED) == State.GUIDING
    m2 = StateMachine(State.MAPPING)
    m2.step(Event.TRACKING_LOST)
    assert m2.step(Event.TRACKING_RECOVERED) == State.MAPPING


def test_tracking_events_guarded():
    m = StateMachine()
    assert not m.can(Event.TRACKING_LOST)      # nothing to interrupt in IDLE
    with pytest.raises(IllegalTransition):
        m.step(Event.TRACKING_RECOVERED)       # not relocalizing


def test_walk_mode_round_trip():
    m = StateMachine()
    assert m.step(Event.WALK_TOGGLED) == State.WALKING
    assert m.step(Event.GOAL_SET) == State.PLANNING
