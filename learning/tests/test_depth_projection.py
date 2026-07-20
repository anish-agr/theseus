"""Depth-projection math against synthetic scenes with exact geometry.

The scene: a flat floor at z=0 and an infinite wall at x = WALL_X. Depth
is computed by exact ray-plane intersection, so every assertion checks
the pipeline against ground truth — no fixtures, no tolerance fudging
beyond cell quantization."""

import math

import pytest

from theseus_engine.grid import FREE, OCCUPIED, UNKNOWN, OccupancyGrid

from depth_projection import (CameraPose, Intrinsics, PersistenceFilter,
                              cam_to_world, depth_to_points, fit_floor_height,
                              ingest, pixel_ray_to_floor, split_by_height,
                              unproject)

W, H = 64, 48
K = Intrinsics.from_fov(W, H, hfov_deg=70.0)
POSE = CameraPose(pos=(0.5, 2.0, 1.4), yaw=0.0, pitch=0.5)
WALL_X = 2.23   # deliberately OFF the 5 cm cell boundary: exact-boundary
MAX_RANGE = 5.0  # geometry would turn cell assignment into a float lottery


def synthetic_depth() -> list[list[float]]:
    """Planar Z-depth of the first surface each pixel ray hits."""
    img = [[0.0] * W for _ in range(H)]
    _r, _d, f = POSE.axes()
    for v in range(H):
        for u in range(W):
            p1 = cam_to_world(unproject(u, v, 1.0, K), POSE)
            dx = (p1[0] - POSE.pos[0], p1[1] - POSE.pos[1], p1[2] - POSE.pos[2])
            ts = []
            if dx[2] < -1e-9:                       # floor z=0
                ts.append(POSE.pos[2] / -dx[2])
            if dx[0] > 1e-9:                        # wall x=WALL_X
                ts.append((WALL_X - POSE.pos[0]) / dx[0])
            if not ts:
                continue
            t = min(ts)
            hit = (POSE.pos[0] + t * dx[0], POSE.pos[1] + t * dx[1],
                   POSE.pos[2] + t * dx[2])
            # planar Z-depth = projection of (hit - pos) onto forward
            z = ((hit[0] - POSE.pos[0]) * f[0] + (hit[1] - POSE.pos[1]) * f[1]
                 + (hit[2] - POSE.pos[2]) * f[2])
            if z <= MAX_RANGE:
                img[v][u] = z
    return img


def test_unproject_and_transform_exact_cases():
    # optical center pixel, 2 m out, level camera at 1.5 m
    level = CameraPose(pos=(0.0, 0.0, 1.5), yaw=0.0, pitch=0.0)
    p = cam_to_world(unproject(K.cx, K.cy, 2.0, K), level)
    assert p == pytest.approx((2.0, 0.0, 1.5))
    # yaw 90°: forward is +y
    turned = CameraPose(pos=(0.0, 0.0, 1.5), yaw=math.pi / 2, pitch=0.0)
    p = cam_to_world(unproject(K.cx, K.cy, 2.0, K), turned)
    assert p == pytest.approx((0.0, 2.0, 1.5), abs=1e-9)
    # a pixel below center lands lower than the camera
    p = cam_to_world(unproject(K.cx, K.cy + 10, 2.0, K), level)
    assert p[2] < 1.5


def test_floor_fit_and_height_split():
    pts = depth_to_points(synthetic_depth(), K, POSE, stride=2,
                          max_range=MAX_RANGE)
    assert len(pts) > 200
    floor_z, inliers = fit_floor_height(pts)
    assert floor_z == pytest.approx(0.0, abs=0.05)
    assert inliers > 50
    floor_pts, obstacle_pts, _high = split_by_height(pts, floor_z)
    assert obstacle_pts, "the wall must appear in the obstacle band"
    for p in obstacle_pts:
        assert p[0] == pytest.approx(WALL_X, abs=0.05)   # all on the wall
    for p in floor_pts:
        assert p[0] < WALL_X + 0.05                      # floor is in front


def test_ingest_builds_the_expected_map():
    grid = OccupancyGrid.from_meters(4.0, 4.0, 0.05)
    pts = depth_to_points(synthetic_depth(), K, POSE, stride=2,
                          max_range=MAX_RANGE)
    floor_z, _ = fit_floor_height(pts)
    floor_pts, obstacle_pts, _ = split_by_height(pts, floor_z)
    for tick in range(1, 4):                # a short video, not one frame
        ingest(grid, (POSE.pos[0], POSE.pos[1]), floor_pts, obstacle_pts, tick)
    assert grid.state(grid.world_to_cell((2.225, 2.0))) == OCCUPIED  # wall
    assert grid.state(grid.world_to_cell((1.5, 2.0))) == FREE        # corridor
    assert grid.state(grid.world_to_cell((3.2, 2.0))) == UNKNOWN     # behind wall
    assert grid.state(grid.world_to_cell((0.2, 3.8))) == UNKNOWN     # outside FOV


def test_persistence_filter_rejects_flicker():
    f = PersistenceFilter(hits_needed=2, window=5)
    assert f.confirm([(3, 3)], tick=1) == []          # first sighting: not yet
    assert f.confirm([(3, 3)], tick=2) == [(3, 3)]    # second: confirmed
    assert f.confirm([(9, 9)], tick=3) == []          # unrelated flicker
    assert f.confirm([(9, 9)], tick=20) == []         # too old to pair up


def test_pixel_ray_to_floor_matches_scene_geometry():
    # bottom-center pixel: floor before the wall, x < WALL_X
    hit = pixel_ray_to_floor(K.cx, H - 1, K, POSE)
    assert hit is not None
    assert hit[0] < WALL_X
    assert hit[1] == pytest.approx(2.0, abs=1e-6)     # yaw 0: straight ahead
    # a pixel above the horizon has no floor intersection
    level = CameraPose(pos=(0.0, 0.0, 1.5), yaw=0.0, pitch=0.0)
    assert pixel_ray_to_floor(K.cx, 0, K, level) is None
