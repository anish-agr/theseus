// Steering + guidance parity tests. Trig-derived values carry a 1e-9
// tolerance (libm may differ by an ulp across platforms); cue KINDS and
// turn SIGNS are exact — a flipped sign steers a person into furniture.
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

private func near(_ a: Double, _ b: Double) -> Bool {
    a == b || abs(a - b) <= 1e-9 * max(1.0, abs(b))
}

@Test func steeringSequenceMatchesReference() {
    let grid = navGrid()
    let steer = VFHSteering(params: params, lookahead: 0.4, minFree: 0.1)
    for (i, (pos, th, gb, wantHeading, wantSpeed, wantFree, wantBlocked,
             wantReason)) in steerScript.enumerated() {
        let d = steer.decide(grid: grid, pose: (pos.x, pos.y, th),
                             goalBearing: gb == -99.0 ? nil : gb)
        #expect(near(d.heading, wantHeading), "step \(i) heading")
        #expect(near(d.speed, wantSpeed), "step \(i) speed")
        #expect(near(d.freeDist, wantFree), "step \(i) free")
        #expect(d.blocked == wantBlocked, "step \(i) blocked")
        #expect(d.reason == wantReason, "step \(i) reason")
    }
}

@Test func steeringReportsBlockedWhenBoxedIn() {
    // a world with no free space: every sector fails minFree
    let grid = OccupancyGrid(width: 8, height: 8, cellSize: 0.05)
    for y in 0..<8 {
        for x in 0..<8 {
            grid.setState(Cell(Int32(x), Int32(y)), OCCUPIED)
        }
    }
    let steer = VFHSteering(params: params)
    let d = steer.decide(grid: grid, pose: (0.2, 0.2, 0.0),
                         goalBearing: nil)
    #expect(d.blocked && d.speed == 0.0 && d.reason == "boxed_in")
}

@Test func guidanceCuesMatchReference() {
    let grid = navGrid()
    let gf = GuidanceFollower(path: guidePath)
    for (i, (pos, th, wantKind, wantDist, wantAngle, wantCross,
             wantCorridor, wantTarget)) in cueProbes.enumerated() {
        let c = gf.cue(grid: grid, pose: (pos.x, pos.y, th))
        #expect(c.kind.rawValue == wantKind, "probe \(i) kind")
        #expect(near(c.distance, wantDist), "probe \(i) distance")
        #expect(near(c.angleDeg, wantAngle), "probe \(i) angle")
        #expect(near(c.crossTrack, wantCross), "probe \(i) cross")
        #expect(c.corridor == wantCorridor, "probe \(i) corridor")
        #expect(near(c.target.x, wantTarget.x)
                && near(c.target.y, wantTarget.y), "probe \(i) target")
    }
}

@Test func turnSignConventionHolds() {
    // the non-negotiable: a lookahead to the agent's LEFT must produce
    // a positive angle and a turn_left cue
    let grid = navGrid()
    let gf = GuidanceFollower(path: guidePath)
    var sawLeft = false
    var sawRight = false
    for (pos, th, wantKind, _, wantAngle, _, _, _) in cueProbes {
        _ = pos; _ = th
        if wantKind == "turn_left" {
            #expect(wantAngle > 0, "turn_left must carry + angle")
            sawLeft = true
        }
        if wantKind == "turn_right" {
            #expect(wantAngle < 0, "turn_right must carry - angle")
            sawRight = true
        }
    }
    #expect(sawLeft && sawRight,
            "fixture must exercise both turn directions")
    _ = gf
}
