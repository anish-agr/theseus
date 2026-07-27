// D* Lite — incremental replanning (Koenig & Likhachev, AAAI 2002).
// Port of engine dstar_lite.py; read that file's docstring for the full
// account of the invariants (g / rhs / consistency / the km trick).
//
// Like the Python, this recomputes rhs values exactly (a full min over
// successors) instead of the paper's incremental shortcuts — a few extra
// neighbor evaluations per touched vertex in exchange for removing the
// subtlest class of D* Lite bugs. The A*-equivalence tests are the
// safety net for this port, same as they were for the original.
//
// One deliberate deviation: notifyChanged iterates its affected set in
// sorted order. Python iterates a hash set (arbitrary order); the final
// g/rhs values are order-independent — rhs reads only g, which does not
// change during the sweep — so sorting changes nothing semantically and
// buys run-to-run determinism Swift's randomized Set ordering would lose.

private let EPS = 1e-9

private struct DEntry: Comparable {
    var k1: Double
    var k2: Double
    var seq: Int
    var cell: Cell

    static func < (a: DEntry, b: DEntry) -> Bool {
        if a.k1 != b.k1 { return a.k1 < b.k1 }
        if a.k2 != b.k2 { return a.k2 < b.k2 }
        return a.seq < b.seq
    }

    static func == (a: DEntry, b: DEntry) -> Bool {
        a.k1 == b.k1 && a.k2 == b.k2 && a.seq == b.seq
    }
}

private func keyLess(_ a: (Double, Double), _ b: (Double, Double)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    return a.1 < b.1
}

public final class DStarLite {
    let grid: OccupancyGrid
    let params: PlanParams
    public private(set) var start: Cell
    public let goal: Cell
    var km = 0.0
    var sLast: Cell
    var g: [Cell: Double] = [:]
    var rhs: [Cell: Double] = [:]
    private var heap = BinaryHeap<DEntry>()
    private var entry: [Cell: Int] = [:]
    private var seq = 0

    public init(grid: OccupancyGrid, start: Cell, goal: Cell,
                params: PlanParams) {
        self.grid = grid
        self.params = params
        self.start = start
        self.goal = goal
        self.sLast = start
        self.rhs[goal] = 0.0
        push(goal)
    }

    // ---- small accessors ----------------------------------------------

    private func gv(_ u: Cell) -> Double { g[u] ?? INF }
    private func rhsv(_ u: Cell) -> Double { rhs[u] ?? INF }

    private func h(_ u: Cell) -> Double {
        octile(start, u) * grid.cellSize
    }

    private func key(_ u: Cell) -> (Double, Double) {
        let v = Swift.min(gv(u), rhsv(u))
        if v == INF {
            return (INF, INF)
        }
        return (v + h(u) + km, v)
    }

    // ---- lazy-deletion priority queue -----------------------------------

    private func push(_ u: Cell) {
        let k = key(u)
        seq += 1
        entry[u] = seq
        heap.push(DEntry(k1: k.0, k2: k.1, seq: seq, cell: u))
    }

    private func invalidate(_ u: Cell) {
        entry[u] = nil
    }

    private func topKey() -> (Double, Double) {
        while let top = heap.min, entry[top.cell] != top.seq {
            _ = heap.pop()
        }
        guard let top = heap.min else {
            return (INF, INF)
        }
        return (top.k1, top.k2)
    }

    private func pop() -> ((Double, Double), Cell)? {
        while let e = heap.pop() {
            if entry[e.cell] == e.seq {
                entry[e.cell] = nil
                return ((e.k1, e.k2), e.cell)
            }
        }
        return nil
    }

    private func updateVertex(_ u: Cell) {
        if abs(gv(u) - rhsv(u)) > EPS {
            push(u)
        } else {
            invalidate(u)
        }
    }

    private func recomputeRhs(_ u: Cell) {
        if u == goal {
            updateVertex(u)
            return
        }
        var best = INF
        for (v, _) in grid.neighbors8(u) {
            let c = grid.edgeCost(u, v, params)
            if c == INF {
                continue
            }
            let cand = c + gv(v)
            if cand < best {
                best = cand
            }
        }
        rhs[u] = best
        updateVertex(u)
    }

    // ---- core -----------------------------------------------------------

    private func computeShortestPath() {
        var guardCount = 0
        let limit = 40 * grid.width * grid.height  // safety net only
        while true {
            guardCount += 1
            precondition(guardCount <= limit,
                         "D* Lite failed to converge (bug)")
            let top = topKey()
            let ks = key(start)
            let startConsistent = abs(rhsv(start) - gv(start)) <= EPS
            if !keyLess(top, ks) && startConsistent {
                break
            }
            guard let (kOld, u) = pop() else {
                break
            }
            let kNew = key(u)
            if keyLess(kOld, kNew) {
                // key went stale (km grew or costs changed): reorder
                push(u)
                continue
            }
            let gu = gv(u)
            let ru = rhsv(u)
            if gu > ru + EPS {
                // overconsistent: this g value is now final
                g[u] = ru
                for (s, _) in grid.neighbors8(u) {
                    recomputeRhs(s)
                }
            } else {
                // underconsistent: invalidate and let the wave repair it
                g[u] = INF
                recomputeRhs(u)
                for (s, _) in grid.neighbors8(u) {
                    recomputeRhs(s)
                }
            }
        }
    }

    /// (Re)compute and extract the current optimal path start -> goal.
    public func plan() -> PlanResult? {
        computeShortestPath()
        if gv(start) == INF {
            return nil
        }
        var cells = [start]
        var cost = 0.0
        var u = start
        let cap = grid.width * grid.height + 1
        while u != goal {
            var bestV: Cell? = nil
            var best = INF
            var bestC = 0.0
            for (v, _) in grid.neighbors8(u) {
                let c = grid.edgeCost(u, v, params)
                if c == INF {
                    continue
                }
                let cand = c + gv(v)
                if cand < best - EPS {
                    best = cand
                    bestV = v
                    bestC = c
                }
            }
            guard let next = bestV, best < INF else {
                return nil
            }
            cost += bestC
            u = next
            cells.append(u)
            if cells.count > cap {
                return nil  // should be unreachable once converged
            }
        }
        return PlanResult(cells: cells, cost: cost)
    }

    // ---- world interface --------------------------------------------------

    /// Call whenever the agent's cell changes. km absorbs the heuristic
    /// drift so stale queue keys stay comparable (the D* Lite trick).
    public func updateStart(_ newStart: Cell) {
        if newStart == start {
            return
        }
        km += h(newStart)  // h measured from the CURRENT start
        start = newStart
        sLast = newStart
    }

    /// Call with every cell whose derived state changed. Edge costs depend
    /// only on the two endpoint cells plus (for diagonals) their shared
    /// cardinal neighbors, all within distance 1 of a changed cell — so
    /// recomputing rhs over the changed cells' 8-neighborhoods repairs
    /// every affected edge.
    public func notifyChanged(_ cells: [Cell]) {
        var affected = Set<Cell>()
        for c in cells {
            if !grid.inBounds(c) {
                continue
            }
            affected.insert(c)
            for (v, _) in grid.neighbors8(c) {
                affected.insert(v)
            }
        }
        for u in affected.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
            recomputeRhs(u)
        }
    }
}
