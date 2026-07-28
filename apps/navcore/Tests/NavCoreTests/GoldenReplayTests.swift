// THE port acceptance milestone (docs/PORT.md): the Swift engine
// replays the golden scenarios and must reproduce the Python trace
// frame-for-frame — same keys, same numbers, same order. Golden files
// were saved with volatile fields stripped, so frames compare directly.
//
// Foundation is allowed here (test target): it loads fixtures/rooms/
// mini.json and fixtures/golden/*-trace.jsonl from the repo.
import Foundation
import Testing
@testable import NavCore

private func repoRoot() -> URL {
    // …/apps/navcore/Tests/NavCoreTests/GoldenReplayTests.swift -> repo
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NavCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // navcore
        .deletingLastPathComponent()   // apps
        .deletingLastPathComponent()   // repo root
}

private func loadMiniRoom() throws -> Room {
    let url = repoRoot().appendingPathComponent("fixtures/rooms/mini.json")
    let data = try Data(contentsOf: url)
    let j = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let size = j["size_m"] as! [Double]
    let rects = (j["rects"] as! [[String: Any]]).map { r in
        RoomRect(x: r["x"] as! Double, y: r["y"] as! Double,
                 w: r["w"] as! Double, h: r["h"] as! Double,
                 label: r["label"] as? String ?? "")
    }
    let start = j["start"] as! [Double]
    let movers = (j["movers"] as? [[String: Any]] ?? []).map { m in
        RoomMover(pts: (m["pts"] as! [[Double]]).map { Vec($0[0], $0[1]) },
                  speed: m["speed"] as? Double ?? 0.5,
                  radius: m["radius"] as? Double ?? 0.25,
                  label: m["label"] as? String ?? "person")
    }
    var waypoints: [String: Vec] = [:]
    for (k, v) in j["waypoints"] as? [String: [Double]] ?? [:] {
        waypoints[k] = Vec(v[0], v[1])
    }
    return Room(cell: j["cell"] as! Double, sizeM: (size[0], size[1]),
                rects: rects, start: Vec(start[0], start[1]),
                startHeading: j["start_heading"] as? Double ?? 0.0,
                movers: movers, waypoints: waypoints)
}

private func miniScanPts() -> [Vec] {
    [Vec(4.3, 0.7), Vec(4.3, 3.3), Vec(0.7, 3.3)]
}

private func loadGolden(_ name: String) throws -> [[String: Any]] {
    let url = repoRoot().appendingPathComponent("fixtures/golden/\(name)")
    let text = try String(contentsOf: url, encoding: .utf8)
    // split(separator: "\n") does NOT split CRLF text — Swift treats
    // "\r\n" as one grapheme cluster that != "\n". isNewline handles
    // both endings, which matters because git checks goldens out CRLF
    // on Windows.
    return try text.split(whereSeparator: \.isNewline).compactMap { raw in
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        return try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any]
    }
}

private func header(_ room: Room, name: String, sim: Simulator,
                    params: PlanParams, sensorRange: Double,
                    fovDeg: Double, scanPts: [Vec]) -> [String: TraceValue] {
    var wps: [String: TraceValue] = [:]
    for (k, v) in room.waypoints {
        wps[k] = .array([.double(v.x), .double(v.y)])
    }
    return [
        "name": .string(name),
        "cell": .double(room.cell),
        "w": .int(sim.est.width),
        "h": .int(sim.est.height),
        "size_m": .array([.double(room.sizeM.0), .double(room.sizeM.1)]),
        "dt": .double(sim.dt),
        "radius": .double(params.radius),
        "sensor": .object(["range": .double(sensorRange),
                           "fov_deg": .double(fovDeg)]),
        "waypoints": .object(wps),
        "furniture": .array(room.rects.map { r in
            .array([.double(r.x), .double(r.y), .double(r.w), .double(r.h),
                    .string(r.label)])
        }),
        "scan_pts": .array(scanPts.map {
            .array([.double($0.x), .double($0.y)])
        }),
    ]
}

// ---- value comparison ----------------------------------------------------

private func numEqual(_ a: Double, _ b: Double) -> Bool {
    a == b
}

private func valueEqual(_ tv: TraceValue, _ any: Any) -> Bool {
    // NOTE: schema keys are typed (blocked is the only bool), so numeric
    // comparison via NSNumber.doubleValue is unambiguous here.
    switch tv {
    case .double(let d):
        if let n = any as? NSNumber {
            return numEqual(d, n.doubleValue)
        }
        return false
    case .int(let i):
        if let n = any as? NSNumber {
            return Double(i) == n.doubleValue
        }
        return false
    case .bool(let b):
        if let n = any as? Bool {
            return b == n
        }
        if let n = any as? NSNumber {
            return b == n.boolValue
        }
        return false
    case .string(let s):
        return s == (any as? String)
    case .array(let arr):
        guard let other = any as? [Any], other.count == arr.count else {
            return false
        }
        for (i, v) in arr.enumerated() where !valueEqual(v, other[i]) {
            return false
        }
        return true
    case .object(let obj):
        guard let other = any as? [String: Any],
              other.count == obj.count else {
            return false
        }
        for (k, v) in obj {
            guard let o = other[k], valueEqual(v, o) else {
                return false
            }
        }
        return true
    }
}

private func compareTrace(_ trace: TraceWriter, _ golden: [[String: Any]],
                          scenario: String) {
    #expect(valueEqual(.object(trace.header), golden[0]),
            Comment(rawValue: "\(scenario): header mismatch"))
    let frames = trace.stableFrames()
    let countMsg = "\(scenario): frame count \(frames.count) vs golden "
        + "\(golden.count - 1)"
    #expect(frames.count == golden.count - 1, Comment(rawValue: countMsg))
    var firstBad = -1
    var badCount = 0
    for (i, frame) in frames.enumerated() where i + 1 < golden.count {
        if !valueEqual(.object(frame), golden[i + 1]) {
            badCount += 1
            if firstBad < 0 { firstBad = i }
        }
    }
    let badMsg = "\(scenario): \(badCount) mismatched frames, first at "
        + "index \(firstBad)"
    #expect(badCount == 0, Comment(rawValue: badMsg))
}

// ---- the three golden scenarios ------------------------------------------

private let goldenParams = PlanParams(radius: 0.28, safeMargin: 0.5,
                                      marginWeight: 1.2)

@Test func goldenMiniGuidance() throws {
    let room = try loadMiniRoom()
    let sim = Simulator(room: room, params: goldenParams,
                        sensorRange: 2.5, sensorFovDeg: 120.0)
    let trace = TraceWriter(header: header(
        room, name: "mini", sim: sim, params: goldenParams,
        sensorRange: 2.5, fovDeg: 120.0, scanPts: miniScanPts()))
    let nav = NavController(sim: sim, params: goldenParams, trace: trace)
    let goal = room.waypoints["target"]!
    let goalCell = sim.est.worldToCell(goal)
    nav.runMapping(scanPts: miniScanPts(), laps: 2) {
        plan(grid: sim.est, start: nav.cell(), goal: goalCell,
             params: goldenParams) != nil
    }
    let arrived = nav.runGuidance(goal: goal, maxTicks: 1200)
    #expect(arrived, "mini guidance must arrive")
    #expect(sim.collisions == 0, "mini guidance must not collide")
    compareTrace(trace, try loadGolden("mini-trace.jsonl"),
                 scenario: "mini")
}

@Test func goldenMiniExplore() throws {
    var room = try loadMiniRoom()
    room.movers = []
    let sim = Simulator(room: room, params: goldenParams,
                        sensorRange: 2.5, sensorFovDeg: 120.0)
    let trace = TraceWriter(header: header(
        room, name: "mini-explore", sim: sim, params: goldenParams,
        sensorRange: 2.5, fovDeg: 120.0, scanPts: []))
    let nav = NavController(sim: sim, params: goldenParams, trace: trace)
    _ = nav.runExplore()
    compareTrace(trace, try loadGolden("mini-explore-trace.jsonl"),
                 scenario: "mini-explore")
}

@Test func goldenMiniWalk() throws {
    let room = try loadMiniRoom()
    let sim = Simulator(room: room, params: goldenParams,
                        sensorRange: 2.5, sensorFovDeg: 120.0)
    let trace = TraceWriter(header: header(
        room, name: "mini-walk", sim: sim, params: goldenParams,
        sensorRange: 2.5, fovDeg: 120.0, scanPts: []))
    let nav = NavController(sim: sim, params: goldenParams, trace: trace)
    let stats = nav.runWalk(ticks: 350)
    #expect(sim.collisions == 0, "mini walk must not collide")
    #expect(stats.blockedTicks == 0)
    compareTrace(trace, try loadGolden("mini-walk-trace.jsonl"),
                 scenario: "mini-walk")
}
