// Flow fields — port of engine flowfield.py: cost-to-nearest-goal for
// EVERY cell from one multi-source Dijkstra sweep. The workhorse behind
// evacuation mode and nearest-semantic queries.
//
// Costs are computed *toward* the goals: the relaxation pulls dist[u]
// from dist[v] via edgeCost(u, v) — u is the cell farther from the goal
// — so the directed source/destination rules are honored exactly.

public final class FlowField {
    let grid: OccupancyGrid
    let params: PlanParams
    let distField: [Double]

    init(grid: OccupancyGrid, params: PlanParams, dist: [Double]) {
        self.grid = grid
        self.params = params
        self.distField = dist
    }

    private struct FEntry: Comparable {
        var d: Double
        var seq: Int
        var cell: Cell

        static func < (a: FEntry, b: FEntry) -> Bool {
            if a.d != b.d { return a.d < b.d }
            return a.seq < b.seq
        }

        static func == (a: FEntry, b: FEntry) -> Bool {
            a.d == b.d && a.seq == b.seq
        }
    }

    /// Multi-source Dijkstra seeded at every traversable goal cell.
    public static func build(grid: OccupancyGrid, goals: [Cell],
                             params: PlanParams) -> FlowField {
        let n = grid.width * grid.height
        var dist = [Double](repeating: INF, count: n)
        var seeds: [FEntry] = []
        var seq = 0
        for g in goals {
            if grid.inBounds(g) && grid.traversable(g, params) {
                let i = grid.idx(g)
                if dist[i] > 0.0 {
                    dist[i] = 0.0
                    seeds.append(FEntry(d: 0.0, seq: seq, cell: g))
                    seq += 1
                }
            }
        }
        var heap = BinaryHeap(seeds)
        while let e = heap.pop() {
            if e.d > dist[grid.idx(e.cell)] + 1e-12 {
                continue  // stale entry
            }
            for (u, _) in grid.neighbors8(e.cell) {
                let c = grid.edgeCost(u, e.cell, params)
                if c == INF {
                    continue
                }
                let nd = e.d + c
                let iu = grid.idx(u)
                if nd < dist[iu] - 1e-12 {
                    dist[iu] = nd
                    heap.push(FEntry(d: nd, seq: seq, cell: u))
                    seq += 1
                }
            }
        }
        return FlowField(grid: grid, params: params, dist: dist)
    }

    /// Cost of walking from `c` to the nearest goal (INF if cut off).
    public func distance(_ c: Cell) -> Double {
        if !grid.inBounds(c) {
            return INF
        }
        return distField[grid.idx(c)]
    }

    /// The neighbor lying on a cheapest route to a goal, or nil if `c`
    /// is a goal / unreachable.
    public func nextStep(_ c: Cell) -> Cell? {
        let dHere = distance(c)
        if dHere == 0.0 || dHere == INF {
            return nil
        }
        var best: Cell? = nil
        var bestD = INF
        for (v, _) in grid.neighbors8(c) {
            let cost = grid.edgeCost(c, v, params)
            if cost == INF {
                continue
            }
            let d = cost + distance(v)
            if d < bestD {
                best = v
                bestD = d
            }
        }
        return best
    }

    /// Greedy descent from `start` to the nearest goal. Each step
    /// strictly decreases the remaining distance (edge costs are
    /// positive), so this terminates with an optimal route.
    public func routeFrom(_ start: Cell) -> PlanResult? {
        let d0 = distance(start)
        if d0 == INF {
            return nil
        }
        var cells = [start]
        var c = start
        let limit = grid.width * grid.height
        while distance(c) > 0.0 && cells.count <= limit {
            guard let nxt = nextStep(c), distance(nxt) < distance(c) else {
                return nil  // defensive: field not converged
            }
            cells.append(nxt)
            c = nxt
        }
        return distance(c) == 0.0 ? PlanResult(cells: cells, cost: d0) : nil
    }
}
