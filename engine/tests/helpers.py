import random

from theseus_engine.grid import FREE, OCCUPIED, OccupancyGrid, PlanParams


def make_random_grid(seed: int, w: int = 32, h: int = 32,
                     density: float = 0.25, cell: float = 0.1) -> OccupancyGrid:
    """Fully-known random grid (no unknown cells)."""
    rng = random.Random(seed)
    g = OccupancyGrid(w, h, cell)
    for y in range(h):
        for x in range(w):
            g.set_state((x, y), OCCUPIED if rng.random() < density else FREE)
    return g


def pick_free_pair(seed: int, g: OccupancyGrid, params: PlanParams):
    """Two distinct traversable cells (or None if the grid is too dense)."""
    rng = random.Random(seed * 7919 + 13)
    cells = [(x, y) for y in range(g.height) for x in range(g.width)
             if g.traversable((x, y), params)]
    if len(cells) < 2:
        return None
    a = rng.choice(cells)
    b = rng.choice(cells)
    tries = 0
    while b == a and tries < 50:
        b = rng.choice(cells)
        tries += 1
    return (a, b) if a != b else None


def open_grid(w: int, h: int, cell: float = 0.05) -> OccupancyGrid:
    """All-FREE grid."""
    g = OccupancyGrid(w, h, cell)
    for y in range(h):
        for x in range(w):
            g.set_state((x, y), FREE)
    return g
