// Flow-field parity tests: full distance fields bit-exact against the
// Python reference, greedy-descent routes identical, and the property
// that single-goal field distance equals a fresh A* cost.
import Testing
@testable import NavCore

private let params = PlanParams(radius: 0.05, safeMargin: 0.15,
                                marginWeight: 1.5)

private func navGrid() -> OccupancyGrid {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ) in navOps {
        grid.observe(Cell(x, y), occupied: occ)
    }
    return grid
}

@Test func distanceFieldsMatchBitExact() {
    let grid = navGrid()
    let single = FlowField.build(grid: grid, goals: [Cell(11, 9)],
                                 params: params)
    let multi = FlowField.build(grid: grid,
                                goals: [Cell(0, 0), Cell(11, 0)],
                                params: params)
    var k = 0
    for y in 0..<10 {
        for x in 0..<12 {
            let c = Cell(Int32(x), Int32(y))
            #expect(single.distance(c) == ffDistSingle[k], "single (\(x),\(y))")
            #expect(multi.distance(c) == ffDistMulti[k], "multi (\(x),\(y))")
            k += 1
        }
    }
}

@Test func routesMatchReference() {
    let grid = navGrid()
    let ff = FlowField.build(grid: grid, goals: [Cell(11, 9)],
                             params: params)
    for (start, wantCells, wantCost) in ffRoutes {
        let r = ff.routeFrom(start)
        #expect(r != nil, "route from \(start)")
        guard let r else { continue }
        #expect(r.cells == wantCells, "route cells from \(start)")
        #expect(r.cost == wantCost, "route cost from \(start)")
    }
}

@Test func singleGoalFieldEqualsAStar() {
    let grid = navGrid()
    let ff = FlowField.build(grid: grid, goals: [Cell(11, 9)],
                             params: params)
    for start in [Cell(0, 0), Cell(0, 9), Cell(6, 1), Cell(2, 2)] {
        let ref = plan(grid: grid, start: start, goal: Cell(11, 9),
                       params: params)
        #expect(ref != nil)
        if let ref {
            #expect(abs(ff.distance(start) - ref.cost) < 1e-9,
                    "field vs A* from \(start)")
        }
    }
}
