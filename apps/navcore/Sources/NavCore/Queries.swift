// Spatial utility queries — port of engine queries.py. The payoff of
// "one world model, many solvers": each of these costs ~20 lines
// because the grid already maintains clearance, semantics and costs.

/// (arcLength, corridorWidth) samples along a world-space polyline.
/// Corridor width at a point is twice the clearance field there.
public func corridorProfile(grid: OccupancyGrid, pts: [Vec],
                            sampleM: Double = 0.15) -> [(Double, Double)] {
    if pts.count < 2 {
        let c = pts.isEmpty ? Cell(0, 0) : grid.worldToCell(pts[0])
        return [(0.0, 2.0 * grid.clearance(c))]
    }
    var out: [(Double, Double)] = []
    var s = 0.0
    for i in 0..<(pts.count - 1) {
        let a = pts[i]
        let b = pts[i + 1]
        let seg = dist(a, b)
        let steps = max(1, Int(seg / sampleM))
        let last = i == pts.count - 2 ? steps + 1 : steps  // endpoint once
        for k in 0..<last {
            let t = Double(k) / Double(steps)
            let p = Vec(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            let width = 2.0 * grid.clearance(grid.worldToCell(p))
            out.append((s + seg * t, width))
        }
        s += seg
    }
    return out
}

/// Can an object of the given width ride this route?
/// Returns (verdict, pinch point or nil, narrowest width).
public func fitsThrough(grid: OccupancyGrid, pts: [Vec], widthM: Double,
                        marginM: Double = 0.05) -> (Bool, Vec?, Double) {
    let need = widthM + 2.0 * marginM
    var worstS = 0.0
    var worstW = INF
    for (s, w) in corridorProfile(grid: grid, pts: pts) {
        if w < worstW {
            worstS = s
            worstW = w
        }
    }
    if worstW >= need {
        return (true, nil, worstW)
    }
    let pinch = pts.count >= 2
        ? pointAlong(pts, startI: 0, startT: 0.0, ahead: worstS)
        : pts[0]
    return (false, pinch, worstW)
}

/// Optimal route to the closest object carrying this semantic label, or
/// nil. The route ends at an *approach point*: the nearest cell the BODY
/// can legally occupy within approachM (arm's reach) of the object —
/// "at the fridge" means standing in front of it, not inside it.
public func nearestSemantic(grid: OccupancyGrid, start: Cell, label: String,
                            params: PlanParams,
                            approachM: Double = 0.75) -> PlanResult? {
    let labeled = grid.labels.compactMap { (i, lab) -> Cell? in
        lab == label ? Cell(Int32(i % grid.width), Int32(i / grid.width))
                     : nil
    }
    if labeled.isEmpty {
        return nil
    }
    let r = max(1, Int(approachM / grid.cellSize))
    var near = Set<Cell>()
    for c in labeled {
        for dy in -r...r {
            for dx in -r...r {
                if dx * dx + dy * dy <= r * r {
                    near.insert(Cell(c.x + Int32(dx), c.y + Int32(dy)))
                }
            }
        }
    }
    let goals = near.filter { grid.inBounds($0) && grid.traversable($0, params) }
        .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    if goals.isEmpty {
        return nil
    }
    return FlowField.build(grid: grid, goals: goals, params: params)
        .routeFrom(start)
}
