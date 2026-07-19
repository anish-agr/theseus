"""Guidance cue geometry. Turn SIGN correctness matters more than anything
here: a guided human told "left" when the path bends right walks into the
obstacle. Conventions: +x right, +y up, heading CCW from +x, positive
bearing error = turn LEFT."""

import math

from theseus_engine.guidance import (ARRIVE, OFF_ROUTE, STRAIGHT, TURN_LEFT,
                                     TURN_RIGHT, GuidanceFollower)
from theseus_engine.grid import PlanParams

from helpers import open_grid

G = open_grid(140, 140)  # 7 x 7 m, empty


def test_straight_ahead():
    f = GuidanceFollower([(1.0, 1.0), (5.0, 1.0)])
    cue = f.cue(G, (1.0, 1.0, 0.0))
    assert cue.kind == STRAIGHT
    assert abs(cue.angle_deg) < 5
    assert math.isclose(cue.distance, 4.0, abs_tol=0.15)  # no turn: to goal


def test_distance_to_next_turn():
    f = GuidanceFollower([(1.0, 1.0), (4.0, 1.0), (4.0, 4.0)])
    cue = f.cue(G, (1.0, 1.0, 0.0))
    assert cue.kind == STRAIGHT
    assert math.isclose(cue.distance, 3.0, abs_tol=0.15)  # to the corner


def test_left_turn_is_positive_angle():
    # path bends up (+y). Facing +x just before the corner -> turn LEFT.
    f = GuidanceFollower([(1.0, 1.0), (3.0, 1.0), (3.0, 3.0)])
    cue = f.cue(G, (2.9, 1.0, 0.0))
    assert cue.kind == TURN_LEFT
    assert cue.angle_deg > 20


def test_right_turn_is_negative_angle():
    # path bends down (-y). Facing +x just before the corner -> turn RIGHT.
    f = GuidanceFollower([(1.0, 3.0), (3.0, 3.0), (3.0, 1.0)])
    cue = f.cue(G, (2.9, 3.0, 0.0))
    assert cue.kind == TURN_RIGHT
    assert cue.angle_deg < -20


def test_arrival():
    f = GuidanceFollower([(1.0, 1.0), (4.0, 1.0)], arrive_radius=0.45)
    cue = f.cue(G, (3.7, 1.1, 0.0))
    assert cue.kind == ARRIVE


def test_off_route_points_back_to_path():
    f = GuidanceFollower([(1.0, 1.0), (6.0, 1.0)], corridor_max=0.9)
    cue = f.cue(G, (3.0, 2.5, 0.0))            # 1.5 m above the path
    assert cue.kind == OFF_ROUTE
    assert math.isclose(cue.cross_track, 1.5, abs_tol=0.05)
    assert math.isclose(cue.target[0], 3.0, abs_tol=0.05)
    assert math.isclose(cue.target[1], 1.0, abs_tol=0.05)
    assert cue.angle_deg < -45                  # path is below: turn right/back


def test_cross_track_reported_while_on_route():
    f = GuidanceFollower([(1.0, 1.0), (6.0, 1.0)])
    cue = f.cue(G, (3.0, 1.3, 0.0))
    assert cue.kind in (STRAIGHT, TURN_LEFT, TURN_RIGHT)
    assert math.isclose(cue.cross_track, 0.3, abs_tol=0.05)
