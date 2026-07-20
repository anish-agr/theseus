"""Frontier exploration: where should a mapping agent go next?

A frontier cell is known-FREE space adjacent to UNKNOWN space — by
definition, standing there reveals something new. Cluster the frontier
cells (single strays are usually sensor noise), rank clusters by real
travel cost from the agent, walk to the nearest, repeat; when no
clusters remain, the reachable world is mapped. This is classic frontier
exploration (Yamauchi 1997) over our grid.

Ranking uses PESSIMISTIC params on purpose: we only chase frontiers we
can reach through space we have already seen. (The controller may still
*walk* optimistically — that is mapping-mode semantics.)

Everything here is deterministic (sorted seeds, ordered expansion): the
explore demo is a golden fixture and the Swift port must reproduce it.
"""

from __future__ import annotations

import heapq
from dataclasses import dataclass

from .geometry import Cell, INF
from .grid import FREE, UNKNOWN, OccupancyGrid, PlanParams

_NBR8 = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))


def frontier_cells(grid: OccupancyGrid) -> list[Cell]:
    out: list[Cell] = []
    for y in range(grid.height):
        for x in range(grid.width):
            if grid.state((x, y)) != FREE:
                continue
            for dx, dy in _NBR8:
                if grid.state((x + dx, y + dy)) == UNKNOWN:
                    out.append((x, y))
                    break
    return out


def clusters(cells: list[Cell], min_size: int = 3) -> list[list[Cell]]:
    """8-connected components of the frontier set; components smaller
    than min_size are dropped as noise."""
    members = set(cells)
    seen: set[Cell] = set()
    out: list[list[Cell]] = []
    for seed in sorted(cells):
        if seed in seen:
            continue
        seen.add(seed)
        comp: list[Cell] = []
        stack = [seed]
        while stack:
            x, y = stack.pop()
            comp.append((x, y))
            for dx, dy in _NBR8:
                n = (x + dx, y + dy)
                if n in members and n not in seen:
                    seen.add(n)
                    stack.append(n)
        if len(comp) >= min_size:
            out.append(comp)
    return out


@dataclass
class FrontierTarget:
    cell: Cell
    cluster_size: int
    travel_cost: float


def select_target(grid: OccupancyGrid, start: Cell, params: PlanParams,
                  min_cluster: int = 3,
                  min_dist_m: float = 0.0) -> FrontierTarget | None:
    """Nearest reachable frontier cluster by real travel cost — a
    frontier on the far side of a wall is far, whatever the crow says.

    min_dist_m skips frontier cells geometrically closer than that: a
    limited-FOV agent always has frontier at the rim of its own body
    disk, and "arriving" there without moving reveals nothing (the
    arrive radius triggers instantly and the rear ring never clears —
    a livelock). Forcing a real walk makes the sensor sweep, which
    clears the near ring as a side effect. The filter is meters, not
    travel cost: margin-inflated costs would let sub-arrive-radius
    cells slip through. Returns None when exploration is complete."""
    comps = clusters(frontier_cells(grid), min_cluster)
    if not comps:
        return None
    d = _dijkstra_from(grid, start, params)
    cs = grid.cell_size
    min_cells_sq = (min_dist_m / cs) ** 2 if cs > 0 else 0.0
    best: FrontierTarget | None = None
    for comp in comps:
        for c in comp:
            dc = d[grid.idx(c)]
            if dc == INF:
                continue
            dx, dy = c[0] - start[0], c[1] - start[1]
            if dx * dx + dy * dy < min_cells_sq:
                continue
            if best is None or dc < best.travel_cost:
                best = FrontierTarget(c, len(comp), dc)
    return best


def _dijkstra_from(grid: OccupancyGrid, start: Cell,
                   params: PlanParams) -> list[float]:
    """Forward travel cost from `start` to every cell (INF: unreachable)."""
    dist = [INF] * (grid.width * grid.height)
    if not grid.in_bounds(start):
        return dist
    dist[grid.idx(start)] = 0.0
    heap: list[tuple[float, int, Cell]] = [(0.0, 0, start)]
    seq = 1
    while heap:
        d, _, u = heapq.heappop(heap)
        if d > dist[grid.idx(u)] + 1e-12:
            continue
        for v, _step in grid.neighbors8(u):
            c = grid.edge_cost(u, v, params)
            if c == INF:
                continue
            nd = d + c
            iv = grid.idx(v)
            if nd < dist[iv] - 1e-12:
                dist[iv] = nd
                heapq.heappush(heap, (nd, seq, v))
                seq += 1
    return dist
