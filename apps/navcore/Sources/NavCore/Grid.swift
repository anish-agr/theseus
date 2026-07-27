// Occupancy world model — line-by-line port of engine grid.py.
//
// Design decisions this port preserves EXACTLY (they are baked into the
// golden fixtures — see the Python docstring for the full rationale):
// - unknown space is NOT traversable by default; mapping/explore opt in
//   via PlanParams(unknownOk: true)
// - clearance measures distance to OCCUPIED cells only
// - no ambient decay: cells persist until re-observed
// - edge costs are directed: destination fully traversable, source only
//   non-occupied (an agent parked closer to a wall than the safety
//   radius must still be able to plan its way out)
// - diagonal moves never cut corners
//
// Port landmines honored here (docs/PORT.md): fromMeters uses banker's
// rounding like Python round(); worldToCell floors (Python //) instead
// of truncating; edgeCost keeps the exact float operation order.

public let UNKNOWN = 0
public let FREE = 1
public let OCCUPIED = 2

public let LO_HIT = 0.85    // log-odds increment for an "occupied" observation
public let LO_MISS = -0.6   // log-odds increment for a "free" observation
// Bounded log-odds: saturation limits how much contrary evidence is
// needed before a cell flips (a person stepping into a long-free
// corridor registers within ~3 observations instead of ~6).
public let LO_MIN = -1.8
public let LO_MAX = 2.5
public let LO_OCC = 0.7     // state thresholds
public let LO_FREE = -0.7

// (dx, dy, step length in cells) — order matters, planners iterate it
let OFFSETS: [(Int32, Int32, Double)] = [
    (1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
    (1, 1, SQRT2), (1, -1, SQRT2), (-1, 1, SQRT2), (-1, -1, SQRT2),
]

/// Canonical cost/safety model shared by A*, D* Lite, steering and
/// smoothing. Both planners MUST see identical costs — the A*/D* Lite
/// equivalence property tests depend on it.
public struct PlanParams: Sendable {
    public var radius: Double        // body radius (m); human ~0.28-0.35
    public var safeMargin: Double    // clearance below which cost rises (m)
    public var marginWeight: Double  // extra cost multiplier at zero clearance
    public var unknownOk: Bool       // may we traverse unseen cells?

    public init(radius: Double = 0.30, safeMargin: Double = 0.55,
                marginWeight: Double = 1.5, unknownOk: Bool = false) {
        self.radius = radius
        self.safeMargin = safeMargin
        self.marginWeight = marginWeight
        self.unknownOk = unknownOk
    }
}

public final class OccupancyGrid {
    public let width: Int
    public let height: Int
    public let cellSize: Double
    public let origin: Vec
    public var lo: [Double]
    public var lastSeen: [Int]
    public var labels: [Int: String] = [:]

    // Clearance cache. clearanceCap (meters) bounds how far the distance
    // transform expands; autoClearance=false lets a simulation throttle
    // recomputes via refreshClearance() and tolerate staleness.
    var clearanceField: [Double]?
    var clearDirty = true
    public var clearanceCap: Double?
    public var autoClearance = true

    public init(width: Int, height: Int, cellSize: Double,
                origin: Vec = Vec(0.0, 0.0)) {
        precondition(width > 0 && height > 0,
                     "grid dimensions must be positive")
        self.width = width
        self.height = height
        self.cellSize = cellSize
        self.origin = origin
        let n = width * height
        self.lo = [Double](repeating: 0.0, count: n)
        self.lastSeen = [Int](repeating: -1, count: n)
    }

    public static func fromMeters(widthM: Double, heightM: Double,
                                  cellSize: Double,
                                  origin: Vec = Vec(0.0, 0.0)) -> OccupancyGrid {
        // Python round() is banker's rounding — .toNearestOrEven, NOT
        // .rounded() (PORT.md landmine 1)
        OccupancyGrid(width: Int((widthM / cellSize).rounded(.toNearestOrEven)),
                      height: Int((heightM / cellSize).rounded(.toNearestOrEven)),
                      cellSize: cellSize, origin: origin)
    }

    // ---- indexing --------------------------------------------------------

    public func idx(_ c: Cell) -> Int {
        Int(c.y) * width + Int(c.x)
    }

    public func inBounds(_ c: Cell) -> Bool {
        0 <= c.x && Int(c.x) < width && 0 <= c.y && Int(c.y) < height
    }

    public func worldToCell(_ p: Vec) -> Cell {
        // Python // is neither truncation NOR floor-of-quotient — see
        // pythonFloorDiv (PORT.md landmine 3, corrected by measurement)
        Cell(Int32(pythonFloorDiv(p.x - origin.x, cellSize)),
             Int32(pythonFloorDiv(p.y - origin.y, cellSize)))
    }

    public func cellCenter(_ c: Cell) -> Vec {
        Vec(origin.x + (Double(c.x) + 0.5) * cellSize,
            origin.y + (Double(c.y) + 0.5) * cellSize)
    }

    // ---- state -----------------------------------------------------------

    /// Out-of-bounds reads as OCCUPIED: the world ends in a wall.
    public func state(_ c: Cell) -> Int {
        if !inBounds(c) {
            return OCCUPIED
        }
        let v = lo[idx(c)]
        if v >= LO_OCC {
            return OCCUPIED
        }
        if v <= LO_FREE {
            return FREE
        }
        return UNKNOWN
    }

    public func blocked(_ c: Cell, unknownOk: Bool) -> Bool {
        let s = state(c)
        return s == OCCUPIED || (s == UNKNOWN && !unknownOk)
    }

    public func label(_ c: Cell) -> String {
        labels[idx(c)] ?? ""
    }

    /// Direct write for simulators and tests. Returns true if the
    /// derived state changed.
    @discardableResult
    public func setState(_ c: Cell, _ newState: Int,
                         label: String = "") -> Bool {
        if !inBounds(c) {
            return false
        }
        let before = state(c)
        let i = idx(c)
        // uses the saturation values, so setState and repeated observe()
        // calls converge to identical log-odds
        switch newState {
        case UNKNOWN: lo[i] = 0.0
        case FREE: lo[i] = LO_MIN
        case OCCUPIED: lo[i] = LO_MAX
        default: preconditionFailure("invalid state \(newState)")
        }
        if !label.isEmpty {
            labels[i] = label
        }
        let after = state(c)
        if (before == OCCUPIED) != (after == OCCUPIED) {
            clearDirty = true  // only the occupied set shapes clearance
        }
        return after != before
    }

    /// Bayesian log-odds update from one sensor reading. Returns true if
    /// the derived state changed (planners need to know).
    @discardableResult
    public func observe(_ c: Cell, occupied: Bool, tick: Int = 0,
                        label: String = "") -> Bool {
        if !inBounds(c) {
            return false
        }
        let i = idx(c)
        let before = state(c)
        let v = lo[i] + (occupied ? LO_HIT : LO_MISS)
        lo[i] = max(LO_MIN, min(LO_MAX, v))
        lastSeen[i] = tick
        if occupied && !label.isEmpty {
            labels[i] = label
        }
        let after = state(c)
        if (before == OCCUPIED) != (after == OCCUPIED) {
            clearDirty = true
        }
        return after != before
    }

    /// (neighbor, step length in cells) for in-bounds 8-neighbors, in the
    /// canonical OFFSETS order.
    public func neighbors8(_ c: Cell) -> [(Cell, Double)] {
        var out: [(Cell, Double)] = []
        out.reserveCapacity(8)
        for (dx, dy, step) in OFFSETS {
            let n = Cell(c.x + dx, c.y + dy)
            if 0 <= n.x && Int(n.x) < width && 0 <= n.y && Int(n.y) < height {
                out.append((n, step))
            }
        }
        return out
    }

    // ---- clearance field ---------------------------------------------------

    /// Octile-metric distance in meters from this cell to the nearest
    /// OCCUPIED cell (0.0 for occupied cells, INF if no obstacle exists).
    /// Computed lazily over the whole grid and cached until any cell's
    /// derived state changes.
    public func clearance(_ c: Cell) -> Double {
        if !inBounds(c) {
            return 0.0
        }
        if clearanceField == nil || (clearDirty && autoClearance) {
            computeClearance()
        }
        return clearanceField![idx(c)]
    }

    /// Recompute the clearance field now if it is stale (or `force`).
    /// Simulations with autoClearance=false call this on their own cadence.
    public func refreshClearance(force: Bool = false) {
        if force || clearanceField == nil || clearDirty {
            computeClearance()
        }
    }

    private struct WaveEntry: Comparable {
        var d: Double
        var x: Int32
        var y: Int32
        // Python heapq orders (d, x, y) tuples lexicographically
        static func < (a: WaveEntry, b: WaveEntry) -> Bool {
            if a.d != b.d { return a.d < b.d }
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
    }

    private func computeClearance() {
        // Multi-source Dijkstra from every occupied cell, expanding with
        // 1 / sqrt(2) step weights: the exact octile distance transform
        // (obstacles do not occlude it; the wave crosses cells freely).
        let n = width * height
        let cs = cellSize
        let cap = clearanceCap.map { $0 / cs } ?? INF
        var dist = [Double](repeating: cap, count: n)
        var seeds: [WaveEntry] = []
        for y in 0..<height {
            let base = y * width
            for x in 0..<width {
                let i = base + x
                if lo[i] >= LO_OCC {
                    dist[i] = 0.0
                    seeds.append(WaveEntry(d: 0.0, x: Int32(x), y: Int32(y)))
                }
            }
        }
        var heap = BinaryHeap(seeds)
        while let e = heap.pop() {
            let i = Int(e.y) * width + Int(e.x)
            if e.d > dist[i] {
                continue
            }
            for (dx, dy, step) in OFFSETS {
                let nx = e.x + dx
                let ny = e.y + dy
                if 0 <= nx && Int(nx) < width && 0 <= ny && Int(ny) < height {
                    let ni = Int(ny) * width + Int(nx)
                    let nd = e.d + step
                    if nd < dist[ni] && nd < cap {
                        dist[ni] = nd
                        heap.push(WaveEntry(d: nd, x: nx, y: ny))
                    }
                }
            }
        }
        clearanceField = dist.map { $0 * cs }
        clearDirty = false
    }

    /// Smallest clearance along the straight segment a-b (world coords).
    /// A corridor admits width w iff the result >= w/2.
    public func minClearanceAlong(_ a: Vec, _ b: Vec,
                                  sample: Double = 0.5) -> Double {
        let length = dist(a, b)
        let steps = max(1, Int(length / (cellSize * sample)))
        var best = INF
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let p = Vec(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            best = min(best, clearance(worldToCell(p)))
        }
        return best
    }

    // ---- canonical cost model ----------------------------------------------

    public func traversable(_ c: Cell, _ p: PlanParams) -> Bool {
        !blocked(c, unknownOk: p.unknownOk) && clearance(c) >= p.radius
    }

    /// >= 1.0 everywhere; rises linearly as clearance drops below
    /// safeMargin, so planners prefer corridor centers without forbidding
    /// tight-but-legal passages.
    public func cellCost(_ c: Cell, _ p: PlanParams) -> Double {
        let cl = clearance(c)
        if cl >= p.safeMargin {
            return 1.0
        }
        return 1.0 + p.marginWeight * (p.safeMargin - cl) / p.safeMargin
    }

    /// Directed cost of moving a -> b, INF if the move is illegal.
    /// The single cost function shared by A*, D* Lite and smoothing.
    public func edgeCost(_ a: Cell, _ b: Cell, _ p: PlanParams) -> Double {
        if !inBounds(a) || !inBounds(b) {
            return INF
        }
        if state(a) == OCCUPIED {
            return INF
        }
        if !traversable(b, p) {
            return INF
        }
        let dx = b.x - a.x
        let dy = b.y - a.y
        let step: Double
        if dx != 0 && dy != 0 {
            // no corner cutting: both shared cardinal cells must be passable
            if blocked(Cell(a.x + dx, a.y), unknownOk: p.unknownOk) {
                return INF
            }
            if blocked(Cell(a.x, a.y + dy), unknownOk: p.unknownOk) {
                return INF
            }
            step = SQRT2
        } else {
            step = 1.0
        }
        // float op ORDER is part of the contract (PORT.md landmine 5)
        return step * cellSize * 0.5 * (cellCost(a, p) + cellCost(b, p))
    }
}
