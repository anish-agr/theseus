// D* Lite tests — replay the scripted world-change scenario and hold the
// incremental planner to three standards at every step:
//   1. its cost matches the Python reference (fixture)
//   2. its cost matches a fresh SWIFT A* plan — the A*-equivalence
//      property, now checked cross-language
//   3. its extracted path is legal and its cost equals the path's sum
import Testing
@testable import NavCore

private let params = PlanParams(radius: 0.05, safeMargin: 0.15,
                                marginWeight: 1.5)

@Test func incrementalReplanningMatchesReferenceAndAStar() {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ) in navOps {
        grid.observe(Cell(x, y), occupied: occ)
    }
    let goal = Cell(11, 9)
    let ds = DStarLite(grid: grid, start: Cell(0, 0), goal: goal,
                       params: params)

    for (i, (writes, move, wantCost)) in dstarSteps.enumerated() {
        var changed: [Cell] = []
        for (x, y, st) in writes {
            grid.setState(Cell(x, y), st)
            changed.append(Cell(x, y))
        }
        if !changed.isEmpty {
            ds.notifyChanged(changed)
        }
        if move != Cell(-99, -99) {
            ds.updateStart(move)
        }
        let res = ds.plan()
        let ref = plan(grid: grid, start: ds.start, goal: goal,
                       params: params)
        if wantCost == INF {
            #expect(res == nil, "step \(i): expected no path")
            #expect(ref == nil, "step \(i): A* disagrees about no-path")
        } else {
            #expect(res != nil, "step \(i): D* found no path")
            guard let res, let ref else { continue }
            #expect(abs(res.cost - wantCost) < 1e-9,
                    "step \(i): cost vs Python reference")
            #expect(abs(res.cost - ref.cost) < 1e-9,
                    "step \(i): cost vs Swift A*")
            #expect(pathCost(grid: grid, cells: res.cells, params: params)
                    == res.cost, "step \(i): path sum")
            #expect(res.cells.first == ds.start && res.cells.last == goal)
        }
    }
}
