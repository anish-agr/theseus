// Grid parity tests — replay the exact observation script the Python
// engine ran (GridParity.swift, generated) and demand bit-identical
// results. Grid math never touches libm, so every comparison here is
// ==, no tolerance: state digits, clearance meters, cell costs, edge
// costs, floor-division cells, banker's-rounding dimensions.
import Testing
@testable import NavCore

private func builtGrid() -> OccupancyGrid {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ, tick, label) in gridOps {
        grid.observe(Cell(x, y), occupied: occ, tick: tick, label: label)
    }
    return grid
}

private let params = PlanParams(radius: 0.05, safeMargin: 0.15,
                                marginWeight: 1.5)

@Test func observeReturnsSameStateChanges() {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (i, (x, y, occ, tick, label)) in gridOps.enumerated() {
        let changed = grid.observe(Cell(x, y), occupied: occ, tick: tick,
                                   label: label)
        #expect(changed == gridChanged[i], "op \(i)")
    }
}

@Test func statesMatchBitExact() {
    let grid = builtGrid()
    let want = Array(gridStates)
    var k = 0
    for y in 0..<10 {
        for x in 0..<12 {
            let digit = Character("\(grid.state(Cell(Int32(x), Int32(y))))")
            #expect(digit == want[k], "cell (\(x),\(y))")
            k += 1
        }
    }
}

@Test func clearanceFieldMatchesBitExact() {
    let grid = builtGrid()
    var k = 0
    for y in 0..<10 {
        for x in 0..<12 {
            #expect(grid.clearance(Cell(Int32(x), Int32(y)))
                    == gridClearance[k], "cell (\(x),\(y))")
            k += 1
        }
    }
}

@Test func costModelMatchesBitExact() {
    let grid = builtGrid()
    var k = 0
    for y in 0..<10 {
        for x in 0..<12 {
            #expect(grid.cellCost(Cell(Int32(x), Int32(y)), params)
                    == gridCellCosts[k], "cell (\(x),\(y))")
            k += 1
        }
    }
    for (a, b, want) in gridEdgeCases {
        #expect(grid.edgeCost(a, b, params) == want, "edge \(a)->\(b)")
    }
}

@Test func worldToCellFloorsLikePython() {
    let grid = builtGrid()
    for (p, want) in worldToCellCases {
        #expect(grid.worldToCell(p) == want, "worldToCell(\(p))")
    }
}

@Test func fromMetersUsesBankersRounding() {
    for (w, h, cell, wantW, wantH) in fromMetersCases {
        let grid = OccupancyGrid.fromMeters(widthM: w, heightM: h,
                                            cellSize: cell)
        #expect(grid.width == wantW && grid.height == wantH,
                "fromMeters(\(w), \(h), \(cell))")
    }
}

@Test func minClearanceAlongMatches() {
    let grid = builtGrid()
    for (a, b, want) in minClearanceCases {
        #expect(grid.minClearanceAlong(a, b) == want)
    }
}

@Test func labelsMatch() {
    let grid = builtGrid()
    #expect(grid.labels.count == gridLabels.count)
    for (i, lab) in gridLabels {
        #expect(grid.labels[i] == lab, "label at idx \(i)")
    }
}

@Test func contractSanity() {
    let grid = builtGrid()
    // out of bounds reads as OCCUPIED — the world ends in a wall
    #expect(grid.state(Cell(-1, 0)) == OCCUPIED)
    #expect(grid.state(Cell(12, 10)) == OCCUPIED)
    // unknown is untraversable by default, opt-in for explore
    let unknownCell = (0..<120).first { grid.lo[$0] == 0.0 }
    if let i = unknownCell {
        let c = Cell(Int32(i % 12), Int32(i / 12))
        #expect(!grid.traversable(c, PlanParams()))
        #expect(grid.blocked(c, unknownOk: true) == false
                || grid.state(c) == OCCUPIED)
    }
}
