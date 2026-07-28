// NavEngine — the app-side owner of the ported NavCore stack: the
// shared occupancy grid, D* Lite routing, guidance cues and the trace
// recorder. ARSessionManager feeds it observations; SwiftUI reads its
// published state.
//
// Coordinate mapping, fixed once here: ARKit is x right / y up / z
// toward the viewer. The floor plan uses the engine convention (+y up
// in a top-down view), so plan-x = ARKit x and plan-y = -ARKit z.
import Combine
import Foundation
import NavCore
import SwiftData

struct LocateTarget: Equatable {
    let thingID: UUID
    let name: String
    let x: Double
    let y: Double
}

@MainActor
final class NavEngine: ObservableObject {
    static let mapSide = 14.0        // metres per room map
    static let cell = 0.05

    private(set) var grid: OccupancyGrid
    let params = PlanParams(radius: 0.30, safeMargin: 0.5,
                            marginWeight: 1.2)
    let fsm = StateMachine()

    @Published var pose: (x: Double, y: Double, heading: Double) = (0, 0, 0)
    @Published var cue: GuidanceCue?
    @Published var goal: Vec?
    @Published var goalName: String = ""
    @Published var smoothedPath: [Vec] = []
    @Published var trackingLimited = false
    @Published var isGuiding = false
    @Published var coverage: Double = 0
    @Published var floorAreaM2: Double = 0
    /// True when the frontier solver finds nothing reachable left to
    /// map. THIS is "done", not a percentage: a real room always keeps
    /// some frontier (under the couch, past a doorway), so a raw
    /// fraction stalls around 70-80% forever and reads as failure.
    @Published var scanComplete = false
    /// Set when a route was requested but cannot exist yet; the UI
    /// shows it as a toast instead of flipping to the guidance screen.
    @Published var routeProblem: String?
    /// A thing being located: camera overlay highlights it, the locate
    /// card tracks live distance/bearing. Lighter than full guidance.
    @Published var locateTarget: LocateTarget?
    @Published var scanHint: String = "Sweep the phone slowly across the floor"
    @Published var statusLine = ""
    @Published var recording = false
    @Published var gridRevision = 0     // bumped so the minimap redraws
    /// Which Room the grid belongs to — guards against scanning one
    /// room into another room's map after a switch.
    @Published var currentRoomID: UUID?

    private var dstar: DStarLite?
    private var follower: GuidanceFollower?
    private var pathCells: [Cell] = []
    private var pendingChanges: [Cell] = []
    private var clearanceAge = 0
    private var trace: TraceWriter?
    private var traceTick = 0

    init() {
        grid = NavEngine.makeGrid()
    }

    private static func makeGrid() -> OccupancyGrid {
        let g = OccupancyGrid(
            width: Int(mapSide / cell), height: Int(mapSide / cell),
            cellSize: cell,
            origin: Vec(-mapSide / 2, -mapSide / 2))
        g.clearanceCap = 1.2
        g.autoClearance = false
        return g
    }

    // ---- room lifecycle --------------------------------------------------

    func resetForNewRoom(id: UUID? = nil) {
        grid = NavEngine.makeGrid()
        clearGuidance()
        coverage = 0
        floorAreaM2 = 0
        scanComplete = false
        locateTarget = nil
        currentRoomID = id
        gridRevision += 1
    }

    func adopt(grid loaded: OccupancyGrid, roomID: UUID) {
        grid = loaded
        grid.clearanceCap = 1.2
        grid.autoClearance = false
        grid.refreshClearance(force: true)
        currentRoomID = roomID
        scanComplete = false      // re-derived on the next tick
        locateTarget = nil        // positions belong to the old room
        recomputeCoverage()
        gridRevision += 1
    }

    /// Make `room` the active map: load its saved grid (or start empty)
    /// unless it already is active. Callers that also run AR must
    /// separately activate the room's world map on the session.
    func makeActive(_ room: Room) {
        guard currentRoomID != room.id else { return }
        if let saved = Store.loadGrid(room.id) {
            adopt(grid: saved, roomID: room.id)
        } else {
            resetForNewRoom(id: room.id)
        }
    }

    // ---- observations ----------------------------------------------------

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

    /// Called by the AR layer at ~5 Hz after feeding observations.
    func tick() {
        clearanceAge += 1
        if clearanceAge >= 5 {
            clearanceAge = 0
            grid.refreshClearance()
            recomputeCoverage()
            updateScanHint()
            gridRevision += 1
        }
        if isGuiding, goal != nil {
            guideTick()
        }
        recordFrame()
    }

    private func recomputeCoverage() {
        var free = 0
        var frontier = 0
        for v in grid.lo {
            if v <= LO_FREE { free += 1 }
        }
        // frontier cells are the honest denominator for "how much is
        // left": known floor that still borders the unknown
        frontier = frontierCells(grid).count
        floorAreaM2 = Double(free) * grid.cellSize * grid.cellSize
        let denom = Double(free + frontier * 4)
        coverage = denom > 0 ? min(1, Double(free) / denom) : 0
    }

    /// Turn the frontier solver into a nudge: which way is unmapped.
    private func updateScanHint() {
        let here = grid.worldToCell(Vec(pose.x, pose.y))
        guard let target = selectTarget(grid: grid, start: here,
                                        params: params, minCluster: 4,
                                        minDistM: 0.6) else {
            // no reachable frontier cluster left = genuinely done
            // (require some real floor first so an empty grid at
            // startup does not count as "complete")
            if floorAreaM2 > 2.0 {
                scanComplete = true
                scanHint = "Scan complete — everything reachable is mapped"
            } else {
                scanHint = "Point at the floor and sweep slowly"
            }
            return
        }
        scanComplete = false
        let centre = grid.cellCenter(target.cell)
        let bearingToTarget = bearing(from: Vec(pose.x, pose.y), to: centre)
        let rel = wrapAngle(bearingToTarget - pose.heading)
        let distance = dist(Vec(pose.x, pose.y), centre)
        let direction: String
        if abs(rel) < 0.5 {
            direction = "ahead"
        } else if rel > 0 {
            direction = "to your left"
        } else {
            direction = "to your right"
        }
        scanHint = String(format: "Unmapped area %@ · %.1f m",
                          direction, distance)
    }

    // ---- guidance --------------------------------------------------------

    /// Route to a target. Only flips into guidance when a route
    /// actually exists — a tap that cannot be served yet becomes a
    /// toast (`routeProblem`), never an empty full-screen takeover.
    @discardableResult
    func startGuidance(to target: Vec, name: String) -> Bool {
        goal = target
        goalName = name
        grid.refreshClearance(force: true)
        let start = grid.worldToCell(Vec(pose.x, pose.y))
        dstar = DStarLite(grid: grid, start: start,
                          goal: grid.worldToCell(target), params: params)
        if fsm.can(.goalSet) { try? fsm.step(.goalSet) }
        replan()
        if follower != nil {
            isGuiding = true
            routeProblem = nil
            return true
        }
        clearGuidance()
        routeProblem = "No route to \(name) yet — scan the floor "
            + "between you and it first"
        return false
    }

    func clearGuidance() {
        goal = nil
        goalName = ""
        follower = nil
        dstar = nil
        smoothedPath = []
        cue = nil
        isGuiding = false
        if fsm.can(.stop) { try? fsm.step(.stop) }
    }

    private func replan() {
        guard let dstar else { return }
        if let res = dstar.plan() {
            pathCells = res.cells
            let sm = smooth(grid: grid, cells: res.cells, params: params)
            follower = GuidanceFollower(path: sm)
            smoothedPath = sm
            if fsm.can(.planReady) { try? fsm.step(.planReady) }
            statusLine = "Follow the route"
        } else {
            follower = nil
            smoothedPath = []
            if fsm.can(.planFailed) { try? fsm.step(.planFailed) }
            statusLine = "No route yet — scan more of the room"
        }
    }

    private func guideTick() {
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

    /// Distance along the current route (nil when not guiding).
    var routeRemainingM: Double? {
        guard isGuiding, !smoothedPath.isEmpty else { return nil }
        return polylineLength([Vec(pose.x, pose.y)] + smoothedPath)
    }

    // ---- space queries ---------------------------------------------------

    /// "Will an object this wide make it from here to there?"
    func fitCheck(from: Vec, to target: Vec,
                  widthM: Double) -> (ok: Bool, pinch: Vec?, narrowest: Double)? {
        grid.refreshClearance(force: true)
        guard let res = plan(grid: grid, start: grid.worldToCell(from),
                             goal: grid.worldToCell(target),
                             params: params) else { return nil }
        let sm = smooth(grid: grid, cells: res.cells, params: params)
        return fitsThrough(grid: grid, pts: sm, widthM: widthM)
    }

    // ---- trace recorder ---------------------------------------------------

    func toggleRecording() {
        if recording {
            recording = false
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
