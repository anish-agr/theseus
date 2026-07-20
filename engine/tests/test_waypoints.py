"""Waypoint registry: merge, promote, decay. These rules are what stand
between a jittery detector and a user command like "go to the fridge"."""

import pytest

from theseus_engine.waypoints import WaypointRegistry


def test_jittered_sightings_merge_and_promote():
    reg = WaypointRegistry(promote_conf=2.5)
    reg.report("fridge", (5.00, 3.00), 0.9, tick=1)
    reg.report("fridge", (5.20, 2.95), 0.8, tick=2)
    wp = reg.report("fridge", (4.95, 3.10), 0.9, tick=3)
    assert len(reg) == 1
    assert wp.promoted is True
    assert wp.hits == 3
    assert wp.pos[0] == pytest.approx(5.05, abs=0.1)
    assert wp.pos[1] == pytest.approx(3.0, abs=0.1)
    assert reg.target_for("fridge") is wp


def test_distant_same_label_objects_stay_distinct():
    reg = WaypointRegistry(merge_radius=0.7)
    reg.report("chair", (1.0, 1.0))
    reg.report("chair", (4.0, 1.0))
    assert len(reg) == 2


def test_single_sighting_is_not_a_target():
    reg = WaypointRegistry(promote_conf=2.5)
    reg.report("plant", (2.0, 2.0), 0.9, tick=1)
    assert reg.target_for("plant") is None
    assert reg.targets() == []


def test_unseen_waypoint_decays_and_dies():
    reg = WaypointRegistry(promote_conf=2.0, miss_decay=0.6, drop_conf=0.25)
    reg.report("cat", (3.0, 3.0), 1.0, tick=1)
    reg.report("cat", (3.0, 3.0), 1.0, tick=2)
    assert reg.target_for("cat") is not None
    for t in range(3, 8):                     # cat wandered off; area re-observed
        reg.observe_area((3.0, 3.0), 2.0, tick=t)
    assert len(reg) == 0
    assert reg.target_for("cat") is None


def test_resighted_waypoint_survives_observation():
    reg = WaypointRegistry(promote_conf=2.0, miss_decay=0.6)
    wp = reg.report("fridge", (5.0, 3.0), 1.0, tick=1)
    reg.report("fridge", (5.0, 3.0), 1.0, tick=2)
    for t in range(3, 20):
        seen = reg.report("fridge", (5.0, 3.0), 1.0, tick=t)
        reg.observe_area((5.0, 3.0), 2.0, tick=t, seen_uids={seen.uid})
    assert reg.get(wp.uid) is not None
    assert reg.get(wp.uid).confidence > 2.0


def test_waypoint_outside_observed_area_untouched():
    reg = WaypointRegistry()
    reg.report("desk", (9.0, 9.0), 2.0, tick=1)
    before = reg.all()[0].confidence
    reg.observe_area((1.0, 1.0), 2.0, tick=2)
    assert reg.all()[0].confidence == before
