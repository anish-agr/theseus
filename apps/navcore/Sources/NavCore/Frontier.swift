// Frontier exploration — port of engine frontier.py (Yamauchi 1997).
// A frontier cell is known-FREE space adjacent to UNKNOWN space;
// cluster them, rank clusters by real travel cost, walk to the nearest.
// Deterministic on purpose (sorted seeds, ordered expansion): the
// explore demo is a golden fixture this port must reproduce.

private let NBR8: [(Int32, Int32)] = [
    (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1),
]

public func frontierCells(_ grid: OccupancyGrid) -> [Cell] {
    var out: [Cell] = []
    for y in 0..<grid.height {
        for x in 0..<grid.width {
            let c = Cell(Int32(x), Int32(y))
            if grid.state(c) != FREE {
                continue
            }
            for (dx, dy) in NBR8 {
                if grid.state(Cell(c.x + dx, c.y + dy)) == UNKNOWN {
                    out.append(c)
                    break
                }
            }
        }
    }
    return out
}

/// 8-connected components of the frontier set; components smaller than
/// minSize are dropped as noise.
public func clusters(_ cells: [Cell], minSize: Int = 3) -> [[Cell]] {
    let members = Set(cells)
    var seen = Set<Cell>()
    var out: [[Cell]] = []
    for seed in cells.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
        if seen.contains(seed) {
            continue
        }
        seen.insert(seed)
        var comp: [Cell] = []
        var stack = [seed]
        while let c = stack.popLast() {
            comp.append(c)
            for (dx, dy) in NBR8 {
                let n = Cell(c.x + dx, c.y + dy)
                if members.contains(n) && !seen.contains(n) {
                    seen.insert(n)
                    stack.append(n)
                }
            }
        }
        if comp.count >= minSize {
            out.append(comp)
        }
    }
    return out
}

public struct FrontierTarget: Sendable {
    public var cell: Cell
    public var clusterSize: Int
    public var travelCost: Double
}

/// Nearest reachable frontier cluster by real travel cost. minDistM
/// skips frontier cells geometrically closer than that — a limited-FOV
/// agent always has frontier at the rim of its own body disk, and
/// "arriving" there without moving reveals nothing (a livelock the
/// Python engine measured; see its docstring). Returns nil when
/// exploration is complete.
public func selectTarget(grid: OccupancyGrid, start: Cell,
                         params: PlanParams, minCluster: Int = 3,
                         minDistM: Double = 0.0) -> FrontierTarget? {
    let comps = clusters(frontierCells(grid), minSize: minCluster)
    if comps.isEmpty {
        return nil
    }
    let d = dijkstraFrom(grid: grid, start: start, params: params)
    let cs = grid.cellSize
    let minCellsSq = cs > 0 ? (minDistM / cs) * (minDistM / cs) : 0.0
    var best: FrontierTarget? = nil
    for comp in comps {
        for c in comp {
            let dc = d[grid.idx(c)]
            if dc == INF {
                continue
            }
            let dx = Double(c.x - start.x)
            let dy = Double(c.y - start.y)
            if dx * dx + dy * dy < minCellsSq {
                continue
            }
            if best == nil || dc < best!.travelCost {
                best = FrontierTarget(cell: c, clusterSize: comp.count,
                                      travelCost: dc)
            }
        }
    }
    return best
}

private struct DijEntry: Comparable {
    var d: Double
    var seq: Int
    var cell: Cell

    static func < (a: DijEntry, b: DijEntry) -> Bool {
        if a.d != b.d { return a.d < b.d }
        return a.seq < b.seq
    }

    static func == (a: DijEntry, b: DijEntry) -> Bool {
        a.d == b.d && a.seq == b.seq
    }
}

/// Forward travel cost from `start` to every cell (INF: unreachable).
func dijkstraFrom(grid: OccupancyGrid, start: Cell,
                  params: PlanParams) -> [Double] {
    var dist = [Double](repeating: INF, count: grid.width * grid.height)
    if !grid.inBounds(start) {
        return dist
    }
    dist[grid.idx(start)] = 0.0
    var heap = BinaryHeap<DijEntry>()
    heap.push(DijEntry(d: 0.0, seq: 0, cell: start))
    var seq = 1
    while let e = heap.pop() {
        if e.d > dist[grid.idx(e.cell)] + 1e-12 {
            continue
        }
        for (v, _) in grid.neighbors8(e.cell) {
            let c = grid.edgeCost(e.cell, v, params)
            if c == INF {
                continue
            }
            let nd = e.d + c
            let iv = grid.idx(v)
            if nd < dist[iv] - 1e-12 {
                dist[iv] = nd
                heap.push(DijEntry(d: nd, seq: seq, cell: v))
                seq += 1
            }
        }
    }
    return dist
}
