// Frontier / coverage / queries parity tests against Python-generated
// fixtures (SolverParity.swift). Cell lists and costs are exact; only
// arc-length values (hypot-derived) carry a tolerance.
import Testing
@testable import NavCore

private let params = PlanParams(radius: 0.05, safeMargin: 0.15,
                                marginWeight: 1.5)

private func partialGrid() -> OccupancyGrid {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ) in partialOps {
        grid.observe(Cell(x, y), occupied: occ)
    }
    return grid
}

private func navQueryGrid() -> OccupancyGrid {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ) in navOps {
        grid.observe(Cell(x, y), occupied: occ)
    }
    grid.setState(Cell(10, 1), OCCUPIED, label: "fridge")
    grid.setState(Cell(1, 8), OCCUPIED, label: "couch")
    return grid
}

private func approx(_ a: Double, _ b: Double) -> Bool {
    a == b || abs(a - b) <= 1e-12 * max(1.0, abs(b))
}

@Test func frontierDetectionMatches() {
    let grid = partialGrid()
    #expect(frontierCells(grid) == frontierCellsWant)
    let comps = clusters(frontierCells(grid), minSize: 3)
    #expect(comps.count == frontierClustersWant.count)
    for (i, comp) in comps.enumerated() {
        #expect(comp == frontierClustersWant[i], "cluster \(i)")
    }
}

@Test func frontierTargetSelectionMatches() {
    let grid = partialGrid()
    let t0 = selectTarget(grid: grid, start: Cell(0, 0), params: params)
    #expect(t0 != nil)
    if let t0 {
        #expect(t0.cell == frontierTarget0.0)
        #expect(t0.clusterSize == frontierTarget0.1)
        #expect(t0.travelCost == frontierTarget0.2)
    }
    let t1 = selectTarget(grid: grid, start: Cell(0, 0), params: params,
                          minDistM: 0.3)
    #expect(t1 != nil)
    if let t1 {
        #expect(t1.cell == frontierTargetMinDist.0)
        #expect(t1.travelCost == frontierTargetMinDist.2)
    }
}

@Test func coverageRouteMatches() {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ) in navOps {
        grid.observe(Cell(x, y), occupied: occ)
    }
    let cov = coverageRoute(grid: grid, start: Cell(0, 0), params: params,
                            laneWidth: 0.2)
    #expect(cov != nil)
    guard let cov else { return }
    #expect(cov.visitPoints == coverageVisit)
    #expect(cov.lanes == coverageLanes)
    #expect(cov.skipped == coverageSkipped)
    #expect(cov.cells.count == coverageCellCount)
    let frac = coverageFraction(grid: grid, route: cov.cells,
                                params: params, laneWidth: 0.2)
    #expect(frac == coverageFrac)
}

@Test func nearestSemanticMatches() {
    let grid = navQueryGrid()
    for (label, wantCells, wantCost) in semanticRoutes {
        let r = nearestSemantic(grid: grid, start: Cell(0, 0), label: label,
                                params: params, approachM: 0.2)
        #expect(r != nil, "route to \(label)")
        guard let r else { continue }
        #expect(r.cells == wantCells, "cells to \(label)")
        #expect(r.cost == wantCost, "cost to \(label)")
    }
    #expect(nearestSemantic(grid: grid, start: Cell(0, 0), label: "ghost",
                            params: params) == nil)
}

@Test func corridorProfileAndFitsMatch() {
    let grid = navQueryGrid()
    let prof = corridorProfile(grid: grid, pts: profilePts)
    #expect(prof.count == profileWant.count)
    for (i, (s, w)) in prof.enumerated() {
        #expect(approx(s, profileWant[i].0), "arc length \(i)")
        #expect(w == profileWant[i].1, "width \(i)")
    }
    for (width, wantOk, wantPinch, wantNarrow) in fitsCases {
        let (ok, pinch, narrow) = fitsThrough(grid: grid, pts: profilePts,
                                              widthM: width)
        #expect(ok == wantOk, "verdict at \(width)")
        #expect(narrow == wantNarrow, "narrowest at \(width)")
        if wantPinch != Vec(-99.0, -99.0) {
            #expect(pinch != nil)
            if let pinch {
                #expect(approx(pinch.x, wantPinch.x)
                        && approx(pinch.y, wantPinch.y))
            }
        } else {
            #expect(pinch == nil)
        }
    }
}
