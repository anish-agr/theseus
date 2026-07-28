// Coverage routes — port of engine coverage.py. Boustrophedon sweep:
// vertical lanes spaced laneWidth apart, walk each lane's reachable runs
// alternately up and down, hop between runs with A*. The guarantee is
// practical, not perfect: coverageFraction reports honestly what
// fraction of reachable floor the route passes within laneWidth of.

public struct CoverageResult: Sendable {
    public var cells: [Cell]        // the full walkable route
    public var visitPoints: [Cell]  // sweep waypoints in visiting order
    public var lanes: Int
    public var skipped: Int         // sweep points no route could reach
}

/// Cells reachable from start under the canonical edge rules.
func reachable(grid: OccupancyGrid, start: Cell,
               params: PlanParams) -> Set<Cell> {
    if !grid.inBounds(start) {
        return []
    }
    var seen: Set<Cell> = [start]
    var queue = [start]
    var head = 0
    while head < queue.count {
        let u = queue[head]
        head += 1
        for (v, _) in grid.neighbors8(u) {
            if !seen.contains(v) && grid.edgeCost(u, v, params) < INF {
                seen.insert(v)
                queue.append(v)
            }
        }
    }
    return seen
}

public func coverageRoute(grid: OccupancyGrid, start: Cell,
                          params: PlanParams,
                          laneWidth: Double = 0.6) -> CoverageResult? {
    let reach = reachable(grid: grid, start: start, params: params)
    if reach.isEmpty {
        return nil
    }
    // Python round() — banker's, not .rounded()
    let laneStep = max(1, Int((laneWidth / grid.cellSize)
                              .rounded(.toNearestOrEven)))
    var visit: [Cell] = []
    var lanes = 0
    var upward = true
    for x in stride(from: laneStep / 2, to: grid.width, by: laneStep) {
        let ys = reach.filter { Int($0.x) == x }.map { Int($0.y) }.sorted()
        if ys.isEmpty {
            continue
        }
        lanes += 1
        // contiguous vertical runs (an obstacle splits a lane)
        var runs: [(Int, Int)] = []
        var y0 = ys[0]
        var prev = ys[0]
        for y in ys.dropFirst() {
            if y == prev + 1 {
                prev = y
            } else {
                runs.append((y0, prev))
                y0 = y
                prev = y
            }
        }
        runs.append((y0, prev))
        if !upward {
            runs.reverse()
        }
        for (lo, hi) in runs {
            let a = upward ? Cell(Int32(x), Int32(lo)) : Cell(Int32(x), Int32(hi))
            let b = upward ? Cell(Int32(x), Int32(hi)) : Cell(Int32(x), Int32(lo))
            visit.append(a)
            if b != a {
                visit.append(b)
            }
        }
        upward = !upward
    }
    var cells = [start]
    var cur = start
    var skipped = 0
    for wp in visit {
        guard let res = plan(grid: grid, start: cur, goal: wp,
                             params: params) else {
            skipped += 1
            continue
        }
        cells.append(contentsOf: res.cells.dropFirst())
        cur = wp
    }
    return CoverageResult(cells: cells, visitPoints: visit, lanes: lanes,
                          skipped: skipped)
}

/// Fraction of floor reachable from the route's start that lies within
/// laneWidth (Chebyshev) of some route cell.
public func coverageFraction(grid: OccupancyGrid, route: [Cell],
                             params: PlanParams,
                             laneWidth: Double) -> Double {
    if route.isEmpty {
        return 0.0
    }
    let reach = reachable(grid: grid, start: route[0], params: params)
    if reach.isEmpty {
        return 0.0
    }
    let r = max(1, Int((laneWidth / grid.cellSize)
                       .rounded(.toNearestOrEven)))
    var covered = Set<Cell>()
    for c in route {
        for dy in -r...r {
            for dx in -r...r {
                covered.insert(Cell(c.x + Int32(dx), c.y + Int32(dy)))
            }
        }
    }
    let hit = reach.reduce(0) { covered.contains($1) ? $0 + 1 : $0 }
    return Double(hit) / Double(reach.count)
}
