// Headless simulator — port of engine sim.py. Stands in for ARKit until
// the shell exists: truth grid + movers play the physical room; sense()
// FOV raycasts play the perception layer; est is the SAME OccupancyGrid
// production code navigates. Deterministic — golden traces depend on it.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import CRT
#endif

public struct RoomRect: Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var label: String

    public init(x: Double, y: Double, w: Double, h: Double,
                label: String = "") {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.label = label
    }
}

public struct RoomMover: Sendable {
    public var pts: [Vec]
    public var speed: Double
    public var radius: Double
    public var label: String

    public init(pts: [Vec], speed: Double = 0.5, radius: Double = 0.25,
                label: String = "person") {
        self.pts = pts
        self.speed = speed
        self.radius = radius
        self.label = label
    }
}

public struct Room: Sendable {
    public var cell: Double
    public var sizeM: (Double, Double)
    public var rects: [RoomRect]
    public var start: Vec
    public var startHeading: Double
    public var movers: [RoomMover]
    public var waypoints: [String: Vec]

    public init(cell: Double, sizeM: (Double, Double), rects: [RoomRect],
                start: Vec, startHeading: Double = 0.0,
                movers: [RoomMover] = [], waypoints: [String: Vec] = [:]) {
        self.cell = cell
        self.sizeM = sizeM
        self.rects = rects
        self.start = start
        self.startHeading = startHeading
        self.movers = movers
        self.waypoints = waypoints
    }
}

/// An obstacle ping-ponging along a polyline (a person, a pet, a
/// roomba). Deterministic — golden traces depend on it.
public final class Mover {
    public let pts: [Vec]
    public let speed: Double
    public let radius: Double
    public let label: String
    var s = 0.0
    var dir = 1.0

    public init(_ spec: RoomMover) {
        self.pts = spec.pts
        self.speed = spec.speed
        self.radius = spec.radius
        self.label = spec.label
    }

    private func length() -> Double {
        var total = 0.0
        guard pts.count > 1 else { return total }
        for i in 0..<(pts.count - 1) {
            total += dist(pts[i], pts[i + 1])
        }
        return total
    }

    /// Advance along the polyline; if `avoid` is given, refuse steps
    /// that close within `keepout` of it — people do not walk through
    /// each other, they pause.
    public func advance(dt: Double, avoid: Vec? = nil,
                        keepout: Double = 0.0) {
        let total = length()
        if total <= 1e-9 {
            return
        }
        let oldS = s
        let oldDir = dir
        let oldPos = pos
        s += dir * speed * dt
        while s < 0.0 || s > total {
            if s < 0.0 {
                s = -s
                dir = 1.0
            } else {
                s = 2.0 * total - s
                dir = -1.0
            }
        }
        if let avoid {
            let newPos = pos
            if dist(newPos, avoid) < keepout
                && dist(newPos, avoid) < dist(oldPos, avoid) {
                s = oldS
                dir = oldDir
            }
        }
    }

    public var pos: Vec {
        var remaining = s
        guard pts.count > 1 else { return pts[0] }
        for i in 0..<(pts.count - 1) {
            let a = pts[i]
            let b = pts[i + 1]
            let d = dist(a, b)
            if remaining <= d || i == pts.count - 2 {
                if d <= 1e-9 {
                    return a
                }
                let f = Swift.min(1.0, remaining / d)
                return Vec(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
            }
            remaining -= d
        }
        return pts[pts.count - 1]
    }
}

public final class Simulator {
    public let room: Room
    public let params: PlanParams
    public let dt: Double
    public let sensorRange: Double
    public let sensorFov: Double
    public let rayStep: Double
    public let maxTurnRate: Double
    public private(set) var tick = 0
    public let truth: OccupancyGrid
    public let est: OccupancyGrid
    public var pose: (Double, Double, Double)
    public let movers: [Mover]
    public private(set) var collisions = 0

    public init(room: Room, params: PlanParams, dt: Double = 0.1,
                sensorRange: Double = 3.0, sensorFovDeg: Double = 100.0,
                rayStepDeg: Double = 2.5, maxTurnRate: Double = 3.0) {
        self.room = room
        self.params = params
        self.dt = dt
        self.sensorFov = sensorFovDeg * (Double.pi / 180.0)
        self.rayStep = rayStepDeg * (Double.pi / 180.0)
        self.sensorRange = sensorRange
        self.maxTurnRate = maxTurnRate

        self.truth = OccupancyGrid.fromMeters(widthM: room.sizeM.0,
                                              heightM: room.sizeM.1,
                                              cellSize: room.cell)
        truth.lo = [Double](repeating: -4.0,
                            count: truth.width * truth.height)  // all FREE
        for r in room.rects {
            Simulator.rasterizeRect(r, into: truth)
        }
        truth.refreshClearance(force: true)

        self.est = OccupancyGrid.fromMeters(widthM: room.sizeM.0,
                                            heightM: room.sizeM.1,
                                            cellSize: room.cell)
        est.clearanceCap = 1.2   // nothing consumes clearance beyond this
        est.autoClearance = false

        self.pose = (room.start.x, room.start.y, room.startHeading)
        self.movers = room.movers.map { Mover($0) }
    }

    private static func rasterizeRect(_ r: RoomRect,
                                      into grid: OccupancyGrid) {
        let cs = grid.cellSize
        let x0 = Int(r.x / cs)
        let y0 = Int(r.y / cs)
        let x1 = Int(((r.x + r.w) / cs).rounded(.up))
        let y1 = Int(((r.y + r.h) / cs).rounded(.up))
        for cy in y0..<y1 {
            for cx in x0..<x1 {
                grid.setState(Cell(Int32(cx), Int32(cy)), OCCUPIED,
                              label: r.label)
            }
        }
    }

    // ---- ground truth queries -------------------------------------------

    public func truthBlocked(_ c: Cell) -> (Bool, String) {
        if truth.state(c) == OCCUPIED {
            return (true, truth.label(c))
        }
        let center = truth.cellCenter(c)
        for m in movers {
            if dist(center, m.pos) <= m.radius + truth.cellSize * 0.5 {
                return (true, m.label)
            }
        }
        return (false, "")
    }

    // ---- per-tick interface ----------------------------------------------

    public func advance() {
        tick += 1
        let agent = Vec(pose.0, pose.1)
        for m in movers {
            m.advance(dt: dt, avoid: agent,
                      keepout: m.radius + params.radius + 0.05)
        }
    }

    /// Cast FOV rays from the pose into ground truth and update the
    /// estimated grid. Returns cells whose derived state changed —
    /// exactly what D* Lite wants to hear about.
    public func sense() -> [Cell] {
        let (x, y, th) = pose
        var changed: [Cell] = []
        let cs = est.cellSize
        // proprioception: the space my own body occupies is free
        let span = Int(params.radius / cs) + 1
        let me = est.worldToCell(Vec(x, y))
        for dy in -span...span {
            for dx in -span...span {
                let c = Cell(me.x + Int32(dx), me.y + Int32(dy))
                if est.inBounds(c)
                    && dist(est.cellCenter(c), Vec(x, y)) <= params.radius {
                    if est.observe(c, occupied: false, tick: tick) {
                        changed.append(c)
                    }
                }
            }
        }
        // FOV raycasts
        let nRays = max(3, Int(sensorFov / rayStep) + 1)
        let march = cs * 0.9
        for k in 0..<nRays {
            let ang = th - sensorFov / 2.0
                + Double(k) * sensorFov / Double(nRays - 1)
            let ca = cos(ang)
            let sa = sin(ang)
            var d = cs * 0.8
            var last: Cell? = nil
            while d <= sensorRange {
                let c = est.worldToCell(Vec(x + ca * d, y + sa * d))
                if !est.inBounds(c) {
                    break
                }
                if c != last {
                    let (blocked, label) = truthBlocked(c)
                    if est.observe(c, occupied: blocked, tick: tick,
                                   label: label) {
                        changed.append(c)
                    }
                    if blocked {
                        break
                    }
                    last = c
                }
                d += march
            }
        }
        return changed
    }

    /// Turn-rate-limited kinematics with body collision checking against
    /// ground truth. Returns true on a (prevented) collision.
    public func stepMotion(headingCmd: Double, speedCmd: Double) -> Bool {
        var (x, y, th) = pose
        let dth = wrapAngle(headingCmd - th)
        let maxDth = maxTurnRate * dt
        th = wrapAngle(th + max(-maxDth, Swift.min(maxDth, dth)))
        var collided = false
        if speedCmd > 1e-6 {
            let nx = x + cos(th) * speedCmd * dt
            let ny = y + sin(th) * speedCmd * dt
            let r = params.radius * 0.8
            var ok = true
            for i in 0..<9 {
                let px: Double
                let py: Double
                if i == 0 {
                    px = nx
                    py = ny
                } else {
                    let a = Double(i - 1) * Double.pi / 4.0
                    px = nx + cos(a) * r
                    py = ny + sin(a) * r
                }
                if truthBlocked(truth.worldToCell(Vec(px, py))).0 {
                    ok = false
                    break
                }
            }
            if ok {
                x = nx
                y = ny
            } else {
                collided = true
                collisions += 1
            }
        }
        pose = (x, y, th)
        return collided
    }

    public func moverPositions() -> [[Double]] {
        movers.map { [$0.pos.x, $0.pos.y, $0.radius] }
    }
}
