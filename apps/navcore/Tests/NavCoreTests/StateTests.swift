// Waypoint-registry and snapshot parity tests. The detection stream is
// replayed exactly as Python ran it (report ops carry a label; observe
// ops reuse the tuple shape with the radius in the confidence slot).
import Testing
@testable import NavCore

@Test func waypointStreamMatchesReference() {
    let reg = WaypointRegistry()
    var deadIdx = 0
    for (kind, label, pos, confOrRadius, tick) in wpStream {
        if kind == "report" {
            reg.report(label: label, pos: pos, confidence: confOrRadius,
                       tick: tick)
        } else {
            var seen = Set<String>()
            if tick == 10 {  // the chair was re-sighted this frame
                seen = Set(reg.all().filter { $0.label == "chair" }
                    .map { $0.uid })
            }
            let dead = reg.observeArea(center: pos, radius: confOrRadius,
                                       tick: tick, seenUids: seen)
            #expect(dead == wpDeadLists[deadIdx], "dead list \(deadIdx)")
            deadIdx += 1
        }
    }
    let finals = reg.all()
    #expect(finals.count == wpFinal.count)
    for (i, w) in finals.enumerated() {
        let (uid, label, pos, conf, hits, promoted) = wpFinal[i]
        #expect(w.uid == uid && w.label == label, "wp \(i) identity")
        #expect(w.pos == pos, "wp \(i) position")
        #expect(w.confidence == conf, "wp \(i) confidence")
        #expect(w.hits == hits && w.promoted == promoted, "wp \(i) flags")
    }
    #expect(reg.targets().map { $0.uid } == wpTargets)
}

@Test func snapshotRoundTripMatchesReference() throws {
    let grid = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                             origin: Vec(-0.3, -0.2))
    grid.clearanceCap = 1.2
    for (x, y, occ, tick, label) in gridOps {
        grid.observe(Cell(x, y), occupied: occ, tick: tick, label: label)
    }
    let snap = toSnapshot(grid)
    #expect(snap.states == snapStates)
    #expect(snap.labels.count == snapLabels.count)
    for (k, v) in snapLabels {
        #expect(snap.labels[k] == v, "label at \(k)")
    }
    // round-trip: derived states must survive exactly
    let back = try fromSnapshot(snap)
    for y in 0..<10 {
        for x in 0..<12 {
            let c = Cell(Int32(x), Int32(y))
            #expect(back.state(c) == grid.state(c), "state (\(x),\(y))")
        }
    }
    #expect(back.labels == grid.labels)
}

@Test func diffMatchesReference() {
    let a = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                          origin: Vec(-0.3, -0.2))
    let b = OccupancyGrid(width: 12, height: 10, cellSize: 0.05,
                          origin: Vec(-0.3, -0.2))
    for g in [a, b] {
        g.clearanceCap = 1.2
        for (x, y, occ, tick, label) in gridOps {
            g.observe(Cell(x, y), occupied: occ, tick: tick, label: label)
        }
    }
    b.setState(Cell(0, 0), OCCUPIED, label: "crate")
    b.setState(Cell(3, 1), FREE)
    let d = gridDiff(a, b)
    #expect(d.count == diffWant.count)
    for (i, (c, sa, sb)) in d.enumerated() {
        #expect(c == diffWant[i].0 && sa == diffWant[i].1
                && sb == diffWant[i].2, "diff entry \(i)")
    }
    let rep = diffReport(a, b)
    #expect(rep.appeared == diffAppeared)
    #expect(rep.vanished == diffVanished)
    #expect(rep.byLabel == diffByLabel)
}
