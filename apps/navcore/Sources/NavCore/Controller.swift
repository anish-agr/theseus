// NavController — port of engine controller.py: wires perception, world
// model, planners, steering, guidance and the FSM into a per-tick loop.
// On iOS this becomes the actor pipeline; the order of operations per
// tick is meant to survive that translation:
//   advance world -> sense -> notify planner -> validate path ->
//   (replan via FSM) -> cue -> steer -> move -> emit trace frame.
//
// replan_ms is volatile (excluded from golden comparison), so this port
// simply omits it — behavior parity is unaffected.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import CRT
#endif

public struct ControllerConfig: Sendable {
    public var mapReplanEvery = 40    // ticks between scheduled map replans
    public var clearanceEvery = 5     // ticks between clearance refreshes
    public var wpArrive = 0.5         // m: "reached this scan waypoint"
    public var blockedWait = 15       // ticks in BLOCKED before RETRY
    public var blockedSteerLimit = 8  // consecutive boxed-in -> force replan
    public var guidanceLookahead = 0.9
    public var pivotThresh = 0.45     // rad: above this -> turn in place

    public init() {}
}

public func pyRound3(_ x: Double) -> Double {
    let r = (x * 1e3).rounded(.toNearestOrEven) / 1e3
    return r == 0 ? 0.0 : r
}

public final class NavController {
    public let sim: Simulator
    public let params: PlanParams
    public let optParams: PlanParams
    public let cfg: ControllerConfig
    public let fsm = StateMachine()
    public let trace: TraceWriter?
    public let steerGuide: VFHSteering
    public let steerMap: VFHSteering
    public private(set) var replans = 0
    public private(set) var frames = 0

    public init(sim: Simulator, params: PlanParams,
                trace: TraceWriter? = nil,
                config: ControllerConfig = ControllerConfig()) {
        self.sim = sim
        self.params = params
        var opt = params
        opt.unknownOk = true
        self.optParams = opt
        self.cfg = config
        self.trace = trace
        self.steerGuide = VFHSteering(params: params)
        self.steerMap = VFHSteering(params: opt)
    }

    // ---- helpers ---------------------------------------------------------

    func pos() -> Vec {
        Vec(sim.pose.0, sim.pose.1)
    }

    func cell() -> Cell {
        sim.est.worldToCell(pos())
    }

    func tickWorld() -> [Cell] {
        sim.advance()
        let changed = sim.sense()
        if sim.tick % cfg.clearanceEvery == 0 {
            sim.est.refreshClearance()
        }
        return changed
    }

    func emit(_ changed: [Cell], cue: GuidanceCue? = nil,
              steer: SteeringDecision? = nil, events: [String] = [],
              path: [Cell]? = nil, smoothed: [Vec]? = nil) {
        guard let trace else { return }
        let (x, y, th) = sim.pose
        var frame: [String: TraceValue] = [
            "t": .double(pyRound3(Double(sim.tick) * sim.dt)),
            "pose": .array([.double(x), .double(y), .double(th)]),
            "state": .string(fsm.state.rawValue),
            "occ": .array(changed.map { c in
                .array([.int(Int(c.x)), .int(Int(c.y)),
                        .int(sim.est.state(c))])
            }),
            "movers": .array(sim.moverPositions().map { m in
                .array(m.map { .double($0) })
            }),
        ]
        if let cue {
            frame["cue"] = .object([
                "kind": .string(cue.kind.rawValue),
                "dist": .double(cue.distance),
                "deg": .double(cue.angleDeg),
                "ct": .double(cue.crossTrack),
                "corridor": .double(cue.corridor),
                "target": .array([.double(cue.target.x),
                                  .double(cue.target.y)]),
            ])
        }
        if let steer {
            frame["steer"] = .object([
                "h": .double(steer.heading),
                "v": .double(steer.speed),
                "free": .double(steer.freeDist),
                "blocked": .bool(steer.blocked),
            ])
        }
        if !events.isEmpty {
            frame["events"] = .array(events.map { .string($0) })
        }
        if let path {
            frame["path"] = .array(path.map { c in
                .array([.int(Int(c.x)), .int(Int(c.y))])
            })
        }
        if let smoothed {
            frame["smoothed"] = .array(smoothed.map { p in
                .array([.double(p.x), .double(p.y)])
            })
        }
        trace.frame(frame)
        frames += 1
    }

    /// Steering validated free space along steer.heading — not along
    /// directions passed through while rotating. Large heading error
    /// means pivot in place first, advance only once roughly aligned.
    func move(_ steer: SteeringDecision) {
        if steer.blocked {
            _ = sim.stepMotion(headingCmd: sim.pose.2, speedCmd: 0.0)
            return
        }
        let err = abs(wrapAngle(steer.heading - sim.pose.2))
        let speed = err > cfg.pivotThresh ? 0.0 : steer.speed
        _ = sim.stepMotion(headingCmd: steer.heading, speedCmd: speed)
    }

    /// Advance a monotone pointer to the path cell nearest the agent
    /// (bounded window), so validity checks only consider the part of
    /// the path still to be walked.
    static func remaining(_ cells: [Cell], _ ptr: Int, _ here: Cell) -> Int {
        var bestI = ptr
        var bestD: Int? = nil
        for i in ptr..<Swift.min(ptr + 12, cells.count) {
            let d = abs(Int(cells[i].x) - Int(here.x))
                + abs(Int(cells[i].y) - Int(here.y))
            if bestD == nil || d < bestD! {
                bestI = i
                bestD = d
            }
        }
        return bestI
    }

    // ---- mapping phase ---------------------------------------------------

    /// Walk the scan waypoints (optimistically planned) to build the
    /// map, like a user sweeping their phone around a room.
    @discardableResult
    public func runMapping(scanPts: [Vec], laps: Int = 2, perWp: Int = 350,
                           doneCheck: (() -> Bool)? = nil) -> Bool {
        try! fsm.step(.scanStarted)
        for _ in 0..<laps {
            for wp in scanPts {
                _ = gotoOptimistic(wp: wp, maxTicks: perWp)
            }
            sim.est.refreshClearance(force: true)
            if let doneCheck, doneCheck() {
                break
            }
        }
        try! fsm.step(.mapReady)
        return true
    }

    func gotoOptimistic(wp: Vec, maxTicks: Int) -> Bool {
        let est = sim.est
        var follower: GuidanceFollower? = nil
        var cells: [Cell]? = nil
        var ptr = 0
        var age = 1_000_000_000
        for _ in 0..<maxTicks {
            let changed = tickWorld()
            if dist(pos(), wp) < cfg.wpArrive {
                emit(changed)
                return true
            }
            age += 1
            let need = cells == nil || age >= cfg.mapReplanEvery
                || !pathValid(grid: est, cells: Array(cells![ptr...]),
                              params: optParams)
            var events: [String] = []
            var pathField: [Cell]? = nil
            var smoothedField: [Vec]? = nil
            if need {
                est.refreshClearance()
                let res = plan(grid: est, start: cell(),
                               goal: est.worldToCell(wp), params: optParams)
                replans += 1
                age = 0
                guard let res else {
                    emit(changed, events: ["WP_UNREACHABLE"])
                    return false  // try again next lap
                }
                cells = res.cells
                ptr = 0
                let smoothed = smooth(grid: est, cells: res.cells,
                                      params: optParams)
                follower = GuidanceFollower(
                    path: smoothed, lookahead: cfg.guidanceLookahead)
                events.append("PLANNED")
                pathField = res.cells
                smoothedField = smoothed
            }
            ptr = NavController.remaining(cells!, ptr, cell())
            let cue = follower!.cue(grid: est, pose: sim.pose)
            if cue.kind == .arrive {
                emit(changed, cue: cue, events: events)
                return true
            }
            let steer = steerMap.decide(
                grid: est, pose: sim.pose,
                goalBearing: bearing(from: pos(), to: cue.target))
            move(steer)
            if cue.kind == .offRoute {
                age = 1_000_000_000  // force replan next tick
            }
            emit(changed, cue: cue, steer: steer, events: events,
                 path: pathField, smoothed: smoothedField)
        }
        return false
    }

    // ---- explore phase (virtual-agent auto-mapping) ----------------------

    /// Frontier-driven auto-mapping: walk to the nearest frontier
    /// cluster until none remain.
    public func runExplore(maxTargets: Int = 60, perTarget: Int = 400,
                           minCluster: Int = 4) -> (targets: Int,
                                                    failures: Int) {
        let est = sim.est
        try! fsm.step(.scanStarted)
        let changed = tickWorld()          // open our eyes before asking
        est.refreshClearance(force: true)
        emit(changed, events: ["EXPLORE_STARTED"])
        var visited = 0
        var failures = 0
        while visited < maxTargets {
            est.refreshClearance(force: true)
            guard let tgt = selectTarget(grid: est, start: cell(),
                                         params: params,
                                         minCluster: minCluster,
                                         minDistM: cfg.wpArrive + 0.25)
            else {
                break
            }
            visited += 1
            if gotoOptimistic(wp: est.cellCenter(tgt.cell),
                              maxTicks: perTarget) {
                failures = 0
            } else {
                failures += 1
                if failures >= 3 {
                    break  // remaining clusters keep defeating us; stop
                }
            }
        }
        try! fsm.step(.mapReady)
        return (visited, failures)
    }

    // ---- walk mode (free roam, no destination) ---------------------------

    /// Walk mode: no destination — VFH picks the most open sector,
    /// hysteresis keeps the choice stable, and two safety gates guard
    /// the advance (see the Python docstrings for the measured
    /// rationale: freshness + swept-body vs live cell states).
    public func runWalk(ticks: Int) -> (traveledM: Double,
                                        blockedTicks: Int) {
        try! fsm.step(.walkToggled)
        var traveled = 0.0
        var blockedTicks = 0
        for _ in 0..<ticks {
            let changed = tickWorld()
            let before = pos()
            var steer = steerMap.decide(grid: sim.est, pose: sim.pose,
                                        goalBearing: nil)
            if !steer.blocked && (!frontFresh(heading: steer.heading)
                                  || !sweptClear(heading: steer.heading)) {
                steer = SteeringDecision(heading: steer.heading, speed: 0.0,
                                         freeDist: steer.freeDist,
                                         blocked: steer.blocked,
                                         reason: "hold_safe")
            }
            move(steer)
            traveled += dist(before, pos())
            blockedTicks += steer.blocked ? 1 : 0
            emit(changed, steer: steer)
        }
        try! fsm.step(.stop)
        return ((traveled * 100).rounded(.toNearestOrEven) / 100,
                blockedTicks)
    }

    /// Swept-body check against LIVE cell states. Gate radius sits just
    /// UNDER body radius on purpose (measured — see Python docstring).
    func sweptClear(heading: Double, advanceM: Double = 0.3,
                    pad: Double = -0.02) -> Bool {
        let est = sim.est
        let (x, y, _) = sim.pose
        let r = params.radius + pad
        let span = Int(r / est.cellSize) + 1
        let ca = cos(heading)
        let sa = sin(heading)
        let step = est.cellSize
        var d = step
        while d <= advanceM {
            let px = x + ca * d
            let py = y + sa * d
            let pc = est.worldToCell(Vec(px, py))
            for dy in -span...span {
                for dx in -span...span {
                    let c = Cell(pc.x + Int32(dx), pc.y + Int32(dy))
                    if est.inBounds(c) && est.state(c) == OCCUPIED
                        && dist(est.cellCenter(c), Vec(px, py)) <= r {
                        return false
                    }
                }
            }
            d += step
        }
        return true
    }

    /// True if every cell within distM along `heading` was observed
    /// within the last maxAge ticks.
    func frontFresh(heading: Double, distM: Double = 0.5,
                    maxAge: Int = 8) -> Bool {
        let est = sim.est
        let (x, y, _) = sim.pose
        let ca = cos(heading)
        let sa = sin(heading)
        let steps = max(1, Int(distM / est.cellSize))
        for i in 1...steps {
            let d = Double(i) * est.cellSize
            let c = est.worldToCell(Vec(x + ca * d, y + sa * d))
            if !est.inBounds(c) {
                return true          // the boundary is a wall, not a mover
            }
            if sim.tick - est.lastSeen[est.idx(c)] > maxAge {
                return false
            }
        }
        return true
    }

    // ---- guidance phase ("Ariadne mode") ---------------------------------

    /// Guide toward `goal` with incremental replanning. Returns true on
    /// arrival.
    public func runGuidance(goal: Vec, maxTicks: Int = 2500) -> Bool {
        let est = sim.est
        est.refreshClearance(force: true)
        let goalCell = est.worldToCell(goal)
        try! fsm.step(.goalSet)

        let ds = DStarLite(grid: est, start: cell(), goal: goalCell,
                           params: params)
        var follower: GuidanceFollower? = nil
        var cells: [Cell]? = nil
        var ptr = 0
        var boxed = 0
        var wait = 0

        func replan(_ events: inout [String]) -> [Cell]? {
            est.refreshClearance()
            let res = ds.plan()
            replans += 1
            guard let res else {
                if fsm.state != .blocked {
                    try! fsm.step(.planFailed)
                }
                events.append("PLAN_FAILED")
                return nil
            }
            let smoothed = smooth(grid: est, cells: res.cells,
                                  params: params)
            follower = GuidanceFollower(path: smoothed,
                                        lookahead: cfg.guidanceLookahead)
            ptr = 0
            try! fsm.step(.planReady)
            events.append("REROUTED")
            return res.cells
        }

        var events: [String] = []
        cells = replan(&events)
        emit([], events: events, path: cells, smoothed: follower?.path)

        for _ in 0..<maxTicks {
            let changed = tickWorld()
            if !changed.isEmpty {
                ds.notifyChanged(changed)
            }
            let here = cell()
            if here != ds.start {
                ds.updateStart(here)
            }

            events = []
            var pathField: [Cell]? = nil
            var smoothedField: [Vec]? = nil

            if fsm.state == .blocked {
                wait += 1
                if wait >= cfg.blockedWait {
                    wait = 0
                    try! fsm.step(.retry)   // BLOCKED -> PLANNING
                    cells = replan(&events)
                    pathField = cells
                    smoothedField = cells != nil ? follower?.path : nil
                }
                emit(changed, events: events, path: pathField,
                     smoothed: smoothedField)
                continue
            }

            ptr = NavController.remaining(cells!, ptr, here)
            if !pathValid(grid: est, cells: Array(cells![ptr...]),
                          params: params) {
                try! fsm.step(.routeBlocked)   // GUIDING -> PLANNING
                cells = replan(&events)
                pathField = cells
                smoothedField = cells != nil ? follower?.path : nil
                if cells == nil {
                    emit(changed, events: events)
                    continue
                }
            }

            var cue = follower!.cue(grid: est, pose: sim.pose)
            if cue.kind == .arrive {
                try! fsm.step(.arrivedEvt)
                emit(changed, cue: cue, events: events + ["ARRIVED"],
                     path: pathField, smoothed: smoothedField)
                return true
            }
            if cue.kind == .offRoute {
                try! fsm.step(.offRoute)      // GUIDING -> PLANNING
                cells = replan(&events)
                pathField = cells
                smoothedField = cells != nil ? follower?.path : nil
                if cells == nil {
                    emit(changed, events: events)
                    continue
                }
                cue = follower!.cue(grid: est, pose: sim.pose)
            }

            let steer = steerGuide.decide(
                grid: est, pose: sim.pose,
                goalBearing: bearing(from: pos(), to: cue.target))
            if steer.blocked {
                boxed += 1
                if boxed >= cfg.blockedSteerLimit {
                    boxed = 0
                    try! fsm.step(.routeBlocked)
                    cells = replan(&events)
                    pathField = cells
                    smoothedField = cells != nil ? follower?.path : nil
                }
            } else {
                boxed = 0
            }
            move(steer)
            emit(changed, cue: cue, steer: steer, events: events,
                 path: pathField, smoothed: smoothedField)
        }
        return false
    }
}
