// Grid snapshots — port of engine serialize.py: save / load / diff, the
// seed of the M2 sidecar format. What persists is the MAP, not sensor
// history: derived states + labels round-trip exactly; log-odds collapse
// to saturation values on load (identical to setState).
//
// Per docs/PORT.md rule 6 the actual JSON bytes live OUTSIDE NavCore
// (Foundation-allowed layers: the app, the replay tests); this file owns
// the semantics — RLE encode/decode and diffing.

public let GRID_SCHEMA = "theseus-grid/1"

public struct GridSnapshot: Sendable {
    public var schema: String
    public var w: Int
    public var h: Int
    public var cell: Double
    public var origin: Vec
    public var states: [Int]          // RLE pairs: state, run, state, run…
    public var labels: [Int: String]
}

public func toSnapshot(_ grid: OccupancyGrid) -> GridSnapshot {
    var states: [Int] = []
    var runState = grid.state(Cell(0, 0))
    var runLen = 0
    for y in 0..<grid.height {
        for x in 0..<grid.width {
            let s = grid.state(Cell(Int32(x), Int32(y)))
            if s == runState {
                runLen += 1
            } else {
                states.append(runState)
                states.append(runLen)
                runState = s
                runLen = 1
            }
        }
    }
    states.append(runState)
    states.append(runLen)
    return GridSnapshot(schema: GRID_SCHEMA, w: grid.width, h: grid.height,
                        cell: grid.cellSize, origin: grid.origin,
                        states: states, labels: grid.labels)
}

public enum SnapshotError: Error {
    case badSchema(String)
    case badLength
}

public func fromSnapshot(_ d: GridSnapshot) throws -> OccupancyGrid {
    guard d.schema == GRID_SCHEMA else {
        throw SnapshotError.badSchema(d.schema)
    }
    let g = OccupancyGrid(width: d.w, height: d.h, cellSize: d.cell,
                          origin: d.origin)
    var i = 0
    var k = 0
    while k < d.states.count {
        let state = d.states[k]
        let run = d.states[k + 1]
        if state != UNKNOWN {  // grids start all-UNKNOWN
            for j in i..<(i + run) {
                g.setState(Cell(Int32(j % g.width), Int32(j / g.width)),
                           state)
            }
        }
        i += run
        k += 2
    }
    guard i == g.width * g.height else {
        throw SnapshotError.badLength
    }
    for (key, lab) in d.labels {
        g.labels[key] = lab
    }
    return g
}

/// Cells whose derived state differs: (cell, state in a, state in b).
public func gridDiff(_ a: OccupancyGrid,
                     _ b: OccupancyGrid) -> [(Cell, Int, Int)] {
    precondition(a.width == b.width && a.height == b.height,
                 "grids must share dimensions to diff")
    var out: [(Cell, Int, Int)] = []
    for y in 0..<a.height {
        for x in 0..<a.width {
            let c = Cell(Int32(x), Int32(y))
            let sa = a.state(c)
            let sb = b.state(c)
            if sa != sb {
                out.append((c, sa, sb))
            }
        }
    }
    return out
}

public struct DiffReport: Sendable, Equatable {
    public var appeared: Int
    public var vanished: Int
    public var byLabel: [String: Int]
}

/// Human-oriented summary of a->b: what appeared, what vanished, grouped
/// by semantic label where one is known.
public func diffReport(_ a: OccupancyGrid, _ b: OccupancyGrid) -> DiffReport {
    var appeared = 0
    var vanished = 0
    var byLabel: [String: Int] = [:]
    for (c, sa, sb) in gridDiff(a, b) {
        if sb == OCCUPIED && sa != OCCUPIED {
            appeared += 1
        } else if sa == OCCUPIED && sb != OCCUPIED {
            vanished += 1
        } else {
            continue
        }
        var lab = b.label(c)
        if lab.isEmpty { lab = a.label(c) }
        if lab.isEmpty { lab = "?" }
        byLabel[lab, default: 0] += 1
    }
    return DiffReport(appeared: appeared, vanished: vanished,
                      byLabel: byLabel)
}
