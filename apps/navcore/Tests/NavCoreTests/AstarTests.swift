// A* parity tests — planned paths must match the Python reference
// cell-for-cell (deterministic tie-breaking makes that a fair demand),
// costs bit-exact, Dijkstra agreeing with A*, smoothing identical.
import Testing
@testable import NavCore

private func scriptedGrid() -> OccupancyGrid {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ) in navOps {
        grid.observe(Cell(x, y), occupied: occ)
    }
    return grid
}

private let params = PlanParams(radius: 0.05, safeMargin: 0.15,
                                marginWeight: 1.5)

@Test func plannedPathsMatchCellForCell() {
    let grid = scriptedGrid()
    for (start, goal, wantCells, wantCost) in planCases {
        let res = plan(grid: grid, start: start, goal: goal, params: params)
        #expect(res != nil, "plan \(start)->\(goal) returned nil")
        guard let res else { continue }
        #expect(res.cells == wantCells, "path \(start)->\(goal)")
        #expect(res.cost == wantCost, "cost \(start)->\(goal)")
    }
}

@Test func dijkstraAgreesWithAStar() {
    let grid = scriptedGrid()
    for (start, goal, _, wantCost) in planCases {
        let dij = plan(grid: grid, start: start, goal: goal, params: params,
                       useHeuristic: false)
        #expect(dij != nil)
        if let dij {
            #expect(abs(dij.cost - wantCost) < 1e-9,
                    "dijkstra cost \(start)->\(goal)")
        }
    }
}

@Test func unreachableReturnsNil() {
    let grid = scriptedGrid()
    for (start, goal) in unreachableCases {
        #expect(plan(grid: grid, start: start, goal: goal,
                     params: params) == nil)
    }
}

@Test func pathCostAndValidity() {
    let grid = scriptedGrid()
    for (_, _, cells, wantCost) in planCases {
        #expect(pathCost(grid: grid, cells: cells, params: params)
                == wantCost)
        #expect(pathValid(grid: grid, cells: cells, params: params))
    }
    #expect(pathCost(grid: grid, cells: badPath, params: params) == INF)
    #expect(!pathValid(grid: grid, cells: badPath, params: params))
    #expect(!pathValid(grid: grid, cells: [], params: params))
}

@Test func smoothingMatchesReference() {
    let grid = scriptedGrid()
    for (i, (_, _, cells, _)) in planCases.enumerated() {
        let sm = smooth(grid: grid, cells: cells, params: params)
        #expect(sm == smoothCases[i], "smooth case \(i)")
    }
}

@Test func corridorChecksMatch() {
    let grid = scriptedGrid()
    for (a, b, want) in corridorCases {
        #expect(corridorClear(grid: grid, a, b, params: params) == want)
    }
}
