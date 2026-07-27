// A* on the occupancy grid — port of engine astar.py.
//
// A* plays two roles: the planner for mapping/explore mode, and the
// ground truth the incremental planner (DStarLite, next in the port
// order) is property-tested against. Also home to path smoothing.
//
// Determinism note: the heap orders (f, g, seq) exactly like Python's
// (f, g, seq, cell) tuples — seq is unique so Python never compares the
// trailing cell, and neither do we. Identical edge costs + identical
// neighbor order + identical tie-breaks = identical paths.

public struct PlanResult: Sendable {
    public var cells: [Cell]
    public var cost: Double

    public init(cells: [Cell], cost: Double) {
        self.cells = cells
        self.cost = cost
    }
}

private struct AStarEntry: Comparable {
    var f: Double
    var g: Double
    var seq: Int
    var cell: Cell

    static func < (a: AStarEntry, b: AStarEntry) -> Bool {
        if a.f != b.f { return a.f < b.f }
        if a.g != b.g { return a.g < b.g }
        return a.seq < b.seq
    }

    static func == (a: AStarEntry, b: AStarEntry) -> Bool {
        a.f == b.f && a.g == b.g && a.seq == b.seq
    }
}

/// Optimal path start -> goal under grid.edgeCost, or nil.
/// With useHeuristic=false this is plain Dijkstra (the independent
/// optimality oracle in tests).
public func plan(grid: OccupancyGrid, start: Cell, goal: Cell,
                 params: PlanParams,
                 useHeuristic: Bool = true) -> PlanResult? {
    if !grid.inBounds(start) || grid.state(start) == OCCUPIED {
        return nil
    }
    if !grid.traversable(goal, params) {
        return nil
    }
    if start == goal {
        return PlanResult(cells: [start], cost: 0.0)
    }

    let cs = grid.cellSize

    // octile * cellSize * (min cell cost = 1.0): admissible & consistent
    func h(_ c: Cell) -> Double {
        useHeuristic ? octile(c, goal) * cs : 0.0
    }

    var g: [Cell: Double] = [start: 0.0]
    var parent: [Cell: Cell] = [:]
    var seq = 0
    var heap = BinaryHeap<AStarEntry>()
    heap.push(AStarEntry(f: h(start), g: 0.0, seq: seq, cell: start))
    while let e = heap.pop() {
        var u = e.cell
        if e.g > (g[u] ?? INF) + 1e-12 {
            continue  // stale entry
        }
        if u == goal {
            var cells = [u]
            while u != start {
                u = parent[u]!
                cells.append(u)
            }
            cells.reverse()
            return PlanResult(cells: cells, cost: e.g)
        }
        for (v, _) in grid.neighbors8(u) {
            let c = grid.edgeCost(u, v, params)
            if c == INF {
                continue
            }
            let ng = e.g + c
            if ng < (g[v] ?? INF) - 1e-12 {
                g[v] = ng
                parent[v] = u
                seq += 1
                heap.push(AStarEntry(f: ng + h(v), g: ng, seq: seq, cell: v))
            }
        }
    }
    return nil
}

public func pathCost(grid: OccupancyGrid, cells: [Cell],
                     params: PlanParams) -> Double {
    var total = 0.0
    guard cells.count > 1 else { return total }
    for i in 0..<(cells.count - 1) {
        let c = grid.edgeCost(cells[i], cells[i + 1], params)
        if c == INF {
            return INF
        }
        total += c
    }
    return total
}

/// Cheap per-tick check that a previously planned path is still legal
/// (the first cell is where the agent stands, so only source rules apply).
public func pathValid(grid: OccupancyGrid, cells: [Cell],
                      params: PlanParams) -> Bool {
    if cells.isEmpty {
        return false
    }
    return pathCost(grid: grid, cells: cells, params: params) < INF
}

// ---- smoothing ------------------------------------------------------------

/// True if every sampled cell along segment a-b is traversable at the
/// agent radius. Fine sampling (default: 0.4 cells) also rules out the
/// diagonal corner-cutting cases the edge model forbids.
public func corridorClear(grid: OccupancyGrid, _ a: Vec, _ b: Vec,
                          params: PlanParams,
                          sample: Double = 0.4) -> Bool {
    let length = dist(a, b)
    let steps = max(1, Int((length / (grid.cellSize * sample)).rounded(.up)))
    for k in 0...steps {
        let t = Double(k) / Double(steps)
        let p = Vec(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        if !grid.traversable(grid.worldToCell(p), params) {
            return false
        }
    }
    return true
}

/// Greedy shortcut smoothing ("string pulling lite"): from each anchor,
/// jump to the farthest path point whose straight corridor is clear.
/// Output is world-space waypoints; endpoints are preserved.
public func smooth(grid: OccupancyGrid, cells: [Cell],
                   params: PlanParams) -> [Vec] {
    let pts = cells.map { grid.cellCenter($0) }
    if pts.count < 3 {
        return pts
    }
    var out = [pts[0]]
    var i = 0
    while i < pts.count - 1 {
        var j = pts.count - 1
        while j > i + 1 && !corridorClear(grid: grid, pts[i], pts[j],
                                          params: params) {
            j -= 1
        }
        out.append(pts[j])
        i = j
    }
    return out
}
