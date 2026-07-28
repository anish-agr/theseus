// NavEngine — the app-side owner of the ported NavCore stack: the
// shared occupancy grid, D* Lite, guidance, FSM, and the trace
// recorder. ARSessionManager feeds it observations; the UI reads its
// published state. v0 runs on the main actor with throttled heavy work
// (clearance refresh ~1 Hz, planning ~5 Hz on a 240x240 grid — cheap);
// the full actor pipeline is the M1.5 refinement.
import Combine
import Foundation
import NavCore

// World mapping: ARKit x right / y up / z toward viewer. Floor plan:
// our x = ARKit x, our y = -ARKit z (so +y is "away from you at session
// start"), matching the engine's +y-up top-down convention.

@MainActor
final class NavEngine: ObservableObject {
    // 12 x 12 m, 5 cm cells, session origin at the center
    static let mapSide = 12.0
    static let cell = 0.05

    let grid: OccupancyGrid
    let params = PlanParams(radius: 0.30, safeMargin: 0.5,
                            marginWeight: 1.2)
    let fsm = StateMachine()

    @Published var mode: Mode = .scan
    @Published var pose: (x: Double, y: Double, heading: Double) = (0, 0, 0)
    @Published var cue: GuidanceCue?
    @Published var goal: Vec?
    @Published var smoothedPath: [Vec] = []
    @Published var trackingLimited = false
    @Published var freeCells = 0
    @Published var occupiedCells = 0
    @Published var statusLine = "Point the phone at the floor and sweep"
    @Published var recording = false
    @Published var agentPos: Vec?

    private var dstar: DStarLite?
    private var follower: GuidanceFollower?
    private var pathCells: [Cell] = []
    private var pendingChanges: [Cell] = []
    private var clearanceAge = 0
    private var trace: TraceWriter?
    private var traceTick = 0
    private var agentHeading = 0.0
    private let agentSteer: VFHSteering

    enum Mode: String {
        case scan = "Scan"
        case guide = "Guide"
        case agent = "Agent"
    }

    init() {
        grid = OccupancyGrid(
            width: Int(NavEngine.mapSide / NavEngine.cell),
            height: Int(NavEngine.mapSide / NavEngine.cell),
            cellSize: NavEngine.cell,
            origin: Vec(-NavEngine.mapSide / 2, -NavEngine.mapSide / 2))
        grid.clearanceCap = 1.2
        grid.autoClearance = false
        var opt = params
        opt.unknownOk = true
        agentSteer = VFHSteering(params: opt)
        try? fsm.step(.scanStarted)
    }

    // ---- observations from ARSessionManager ------------------------------

    func updatePose(x: Double, y: Double, heading: Double) {
        pose = (x, y, heading)
    }

    func observeCells(_ obs: [(Cell, Bool)], tick: Int) {
        for (c, occupied) in obs {
            if grid.observe(c, occupied: occupied, tick: tick) {
                pendingChanges.append(c)
            }
        }
    }

    /// Called by the AR layer ~5 Hz after feeding observations.
    func tick() {
        clearanceAge += 1
        if clearanceAge >= 5 {
            clearanceAge = 0
            grid.refreshClearance()
            recount()
        }
        if mode == .guide, let goal {
            guideTick(goal: goal)
        }
        if mode == .agent {
            agentTick()
        }
        recordFrame()
    }

    private func recount() {
        var free = 0
        var occ = 0
        for v in grid.lo {
            if v <= LO_FREE { free += 1 } else if v >= LO_OCC { occ += 1 }
        }
        freeCells = free
        occupiedCells = occ
    }

    // ---- guide mode ------------------------------------------------------

    func setGoal(_ g: Vec) {
        goal = g
        mode = .guide
        grid.refreshClearance(force: true)
        let start = grid.worldToCell(Vec(pose.x, pose.y))
        dstar = DStarLite(grid: grid, start: start,
                          goal: grid.worldToCell(g), params: params)
        if fsm.can(.goalSet) { try? fsm.step(.goalSet) }
        replan()
    }

    func stopGuidance() {
        goal = nil
        follower = nil
        dstar = nil
        smoothedPath = []
        mode = .scan
        cue = nil
        if fsm.can(.stop) { try? fsm.step(.stop) }
        statusLine = "Guidance stopped"
    }

    private func replan() {
        guard let dstar else { return }
        if let res = dstar.plan() {
            pathCells = res.cells
            let sm = smooth(grid: grid, cells: res.cells, params: params)
            follower = GuidanceFollower(path: sm)
            smoothedPath = sm
            if fsm.can(.planReady) { try? fsm.step(.planReady) }
            statusLine = "Follow the thread"
        } else {
            follower = nil
            smoothedPath = []
            if fsm.can(.planFailed) { try? fsm.step(.planFailed) }
            statusLine = "No route yet — keep scanning"
        }
    }

    private func guideTick(goal g: Vec) {
        guard let dstar else { return }
        if !pendingChanges.isEmpty {
            dstar.notifyChanged(pendingChanges)
            pendingChanges.removeAll()
        }
        let here = grid.worldToCell(Vec(pose.x, pose.y))
        if here != dstar.start {
            dstar.updateStart(here)
        }
        if follower == nil
            || !pathValid(grid: grid, cells: pathCells, params: params) {
            if fsm.can(.routeBlocked) { try? fsm.step(.routeBlocked) }
            replan()
        }
        guard let follower else { return }
        let c = follower.cue(grid: grid,
                             pose: (pose.x, pose.y, pose.heading))
        cue = c
        switch c.kind {
        case .arrive:
            if fsm.can(.arrivedEvt) { try? fsm.step(.arrivedEvt) }
            statusLine = "You have arrived"
        case .offRoute:
            if fsm.can(.offRoute) { try? fsm.step(.offRoute) }
            replan()
        default:
            break
        }
    }

    // ---- agent mode (virtual explorer) -----------------------------------

    func toggleAgent() {
        if mode == .agent {
            mode = .scan
            agentPos = nil
            statusLine = "Agent parked"
        } else {
            mode = .agent
            agentPos = Vec(pose.x, pose.y)
            agentHeading = pose.heading
            statusLine = "Agent exploring"
        }
    }

    private func agentTick() {
        guard var p = agentPos else { return }
        let d = agentSteer.decide(grid: grid,
                                  pose: (p.x, p.y, agentHeading),
                                  goalBearing: nil)
        if !d.blocked {
            let dt = 0.2
            let turn = wrapAngle(d.heading - agentHeading)
            agentHeading = wrapAngle(
                agentHeading + max(-0.6, min(0.6, turn)))
            if abs(turn) < 0.45 {
                let nx = p.x + cos(agentHeading) * d.speed * 0.5 * dt
                let ny = p.y + sin(agentHeading) * d.speed * 0.5 * dt
                let cellAt = grid.worldToCell(Vec(nx, ny))
                if grid.state(cellAt) != OCCUPIED {
                    p = Vec(nx, ny)
                }
            }
        }
        agentPos = p
    }

    // ---- trace recorder --------------------------------------------------

    func toggleRecording() {
        if recording {
            recording = false
            statusLine = "Trace saved — use Share"
        } else {
            trace = TraceWriter(header: [
                "name": .string("iphone-live"),
                "cell": .double(grid.cellSize),
                "w": .int(grid.width),
                "h": .int(grid.height),
                "size_m": .array([.double(NavEngine.mapSide),
                                  .double(NavEngine.mapSide)]),
                "dt": .double(0.2),
                "radius": .double(params.radius),
                "sensor": .object(["source": .string("arkit-xr")]),
                "waypoints": .object([:]),
                "furniture": .array([]),
                "scan_pts": .array([]),
            ])
            traceTick = 0
            recording = true
            statusLine = "Recording trace"
        }
    }

    private func recordFrame() {
        guard recording, let trace else { return }
        traceTick += 1
        var frame: [String: TraceValue] = [
            "t": .double(Double(traceTick) * 0.2),
            "pose": .array([.double(pose.x), .double(pose.y),
                            .double(pose.heading)]),
            "state": .string(fsm.state.rawValue),
            "occ": .array(pendingChanges.map { c in
                .array([.int(Int(c.x)), .int(Int(c.y)),
                        .int(grid.state(c))])
            }),
            "movers": .array([]),
        ]
        if let c = cue {
            frame["cue"] = .object([
                "kind": .string(c.kind.rawValue),
                "dist": .double(c.distance),
                "deg": .double(c.angleDeg),
                "ct": .double(c.crossTrack),
                "corridor": .double(c.corridor),
                "target": .array([.double(c.target.x),
                                  .double(c.target.y)]),
            ])
        }
        if !smoothedPath.isEmpty {
            frame["smoothed"] = .array(smoothedPath.map { p in
                .array([.double(p.x), .double(p.y)])
            })
        }
        trace.frame(frame)
    }

    /// Serialize the recorded trace to viewer-compatible JSONL.
    func traceJSONL() -> String? {
        guard let trace else { return nil }
        var lines = [jsonLine(trace.header)]
        for f in trace.frames {
            lines.append(jsonLine(f))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func jsonLine(_ obj: [String: TraceValue]) -> String {
        func any(_ v: TraceValue) -> Any {
            switch v {
            case .double(let d): return d
            case .int(let i): return i
            case .string(let s): return s
            case .bool(let b): return b
            case .array(let a): return a.map(any)
            case .object(let o): return o.mapValues(any)
            }
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: any(.object(obj)),
            options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
