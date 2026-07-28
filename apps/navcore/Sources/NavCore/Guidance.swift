// Guidance ("Ariadne mode") — port of engine guidance.py: turn a
// planned path into egocentric cues a person can act on without seeing
// the map. On-device these drive haptics, audio and speech; here they
// are a typed value tests can assert on — especially the turn SIGN
// (+angle = turn LEFT, the project-wide convention).
//
// Mechanics: pure pursuit. Project the pose onto the path, hold a
// lookahead point a fixed arclength ahead, report the bearing error.
// Cross-track beyond corridorMax means the human left the corridor.

public enum CueKind: String, Sendable {
    case straight
    case turnLeft = "turn_left"
    case turnRight = "turn_right"
    case arrive
    case offRoute = "off_route"
}

public struct GuidanceCue: Sendable {
    public var kind: CueKind
    public var distance: Double     // m: to next turn / to path / to goal
    public var angleDeg: Double     // bearing error to lookahead; + = LEFT
    public var crossTrack: Double   // m off the path centerline
    public var corridor: Double     // local corridor width (2x clearance), m
    public var target: Vec          // lookahead point (steering aims here)
}

public final class GuidanceFollower {
    public let path: [Vec]
    public let lookahead: Double
    public let corridorMax: Double
    public let arriveRadius: Double
    public let turnThreshDeg: Double
    public let vertexTurnDeg: Double

    public init(path: [Vec], lookahead: Double = 0.9,
                corridorMax: Double = 0.9, arriveRadius: Double = 0.45,
                turnThreshDeg: Double = 22.0, vertexTurnDeg: Double = 28.0) {
        precondition(!path.isEmpty, "empty path")
        self.path = path
        self.lookahead = lookahead
        self.corridorMax = corridorMax
        self.arriveRadius = arriveRadius
        self.turnThreshDeg = turnThreshDeg
        self.vertexTurnDeg = vertexTurnDeg
    }

    /// Nearest point on the path: (point, segment index, t, distance).
    func project(_ p: Vec) -> (Vec, Int, Double, Double) {
        if path.count == 1 {
            let q = path[0]
            return (q, 0, 0.0, dist(p, q))
        }
        var best: (Vec, Int, Double, Double)? = nil
        for i in 0..<(path.count - 1) {
            let (q, t) = projectPointSegment(p, path[i], path[i + 1])
            let d = dist(p, q)
            if best == nil || d < best!.3 {
                best = (q, i, t, d)
            }
        }
        return best!
    }

    /// Arclength from the projection to the first vertex where the path
    /// bends by more than vertexTurnDeg (else to the goal).
    func distToNextTurn(segI: Int, t: Double) -> Double {
        let proj = pointAlong(path, startI: segI, startT: t, ahead: 0.0)
        var acc = segI + 1 < path.count ? dist(proj, path[segI + 1]) : 0.0
        for j in (segI + 1)..<Swift.max(segI + 1, path.count - 1) {
            let dIn = bearing(from: j - 1 >= 0 ? path[j - 1] : proj,
                              to: path[j])
            let dOut = bearing(from: path[j], to: path[j + 1])
            if abs(wrapAngle(dOut - dIn) * (180.0 / Double.pi))
                > vertexTurnDeg {
                return acc
            }
            acc += dist(path[j], path[j + 1])
        }
        return acc
    }

    public func cue(grid: OccupancyGrid,
                    pose: (Double, Double, Double)) -> GuidanceCue {
        let (x, y, th) = pose
        let p = Vec(x, y)
        let goal = path[path.count - 1]
        if dist(p, goal) <= arriveRadius {
            return GuidanceCue(
                kind: .arrive, distance: dist(p, goal), angleDeg: 0.0,
                crossTrack: 0.0,
                corridor: 2.0 * grid.clearance(grid.worldToCell(goal)),
                target: goal)
        }
        let (proj, segI, t, cross) = project(p)
        let corridor = 2.0 * grid.clearance(grid.worldToCell(proj))
        if cross > corridorMax {
            let err = wrapAngle(bearing(from: p, to: proj) - th)
                * (180.0 / Double.pi)
            return GuidanceCue(kind: .offRoute, distance: cross,
                               angleDeg: err, crossTrack: cross,
                               corridor: corridor, target: proj)
        }
        let look = path.count > 1
            ? pointAlong(path, startI: segI, startT: t, ahead: lookahead)
            : goal
        let err = wrapAngle(bearing(from: p, to: look) - th)
            * (180.0 / Double.pi)
        if abs(err) < turnThreshDeg {
            return GuidanceCue(kind: .straight,
                               distance: distToNextTurn(segI: segI, t: t),
                               angleDeg: err, crossTrack: cross,
                               corridor: corridor, target: look)
        }
        return GuidanceCue(kind: err > 0 ? .turnLeft : .turnRight,
                           distance: dist(p, look), angleDeg: err,
                           crossTrack: cross, corridor: corridor,
                           target: look)
    }
}
