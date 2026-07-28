// Reactive local steering ("walk mode") — port of engine steering.py.
// VFH-flavored sector scoring (Borenstein & Koren 1991) with the two
// details that matter in practice: hysteresis (commit window + switch
// margin + previous-choice bonus, or the agent oscillates) and an
// explicit BLOCKED outcome so the state machine can escalate.
//
// SteeringPolicy is the M5 seam: a learned policy (PPO -> Core ML)
// drops in behind the same signature for a live A/B.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import CRT
#endif

public struct SteeringDecision: Sendable {
    public var heading: Double      // absolute commanded heading (rad)
    public var speed: Double        // commanded speed (m/s)
    public var freeDist: Double     // free distance along chosen heading (m)
    public var blocked: Bool        // true: no admissible sector — escalate
    public var reason: String
}

public protocol SteeringPolicy {
    func decide(grid: OccupancyGrid, pose: (Double, Double, Double),
                goalBearing: Double?) -> SteeringDecision
}

public final class VFHSteering: SteeringPolicy {
    public let params: PlanParams
    public let n: Int
    public let lookahead: Double
    public let minFree: Double
    public let wFree: Double
    public let wGoal: Double
    public let wKeep: Double
    public let wPrev: Double
    public let commitTicks: Int
    public let switchMargin: Double
    public let vmax: Double
    private var prev: Double? = nil
    private var hold = 0

    public init(params: PlanParams, nSectors: Int = 36,
                lookahead: Double = 2.5, minFree: Double = 0.45,
                wFree: Double = 1.0, wGoal: Double = 1.8,
                wKeep: Double = 0.35, wPrev: Double = 0.45,
                commitTicks: Int = 3, switchMargin: Double = 0.25,
                vmax: Double = 1.0) {
        self.params = params
        self.n = nSectors
        self.lookahead = lookahead
        self.minFree = minFree
        self.wFree = wFree
        self.wGoal = wGoal
        self.wKeep = wKeep
        self.wPrev = wPrev
        self.commitTicks = commitTicks
        self.switchMargin = switchMargin
        self.vmax = vmax
    }

    public func reset() {
        prev = nil
        hold = 0
    }

    /// March along `ang` and return meters of traversable space (capped
    /// at lookahead). Starts one cell out: the cell under the agent's
    /// own feet is a fact, not an option.
    public func rayFree(grid: OccupancyGrid, pos: Vec, ang: Double) -> Double {
        let step = grid.cellSize * 0.5
        var d = grid.cellSize
        let ca = cos(ang)
        let sa = sin(ang)
        while d <= lookahead {
            let cell = grid.worldToCell(Vec(pos.x + ca * d, pos.y + sa * d))
            if !grid.traversable(cell, params) {
                return d - grid.cellSize * 0.5
            }
            d += step
        }
        return lookahead
    }

    public func decide(grid: OccupancyGrid, pose: (Double, Double, Double),
                       goalBearing: Double? = nil) -> SteeringDecision {
        let (x, y, th) = pose
        var bestAng: Double? = nil
        var bestScore = -Double.infinity
        var bestFree = 0.0
        var prevScore = -Double.infinity
        var prevFree = 0.0
        for k in 0..<n {
            let ang = -Double.pi
                + (Double(k) + 0.5) * (2.0 * Double.pi / Double(n))
            let free = rayFree(grid: grid, pos: Vec(x, y), ang: ang)
            if free < minFree {
                continue
            }
            var score = wFree * (free / lookahead)
            score += wKeep * cos(wrapAngle(ang - th))
            if let gb = goalBearing {
                score += wGoal * cos(wrapAngle(ang - gb))
            }
            if let p = prev {
                score += wPrev * cos(wrapAngle(ang - p))
                if abs(wrapAngle(ang - p)) < Double.pi / Double(n) {
                    prevScore = score
                    prevFree = free
                }
            }
            if score > bestScore {
                bestScore = score
                bestAng = ang
                bestFree = free
            }
        }
        guard var chosenAng = bestAng else {
            prev = nil
            hold = 0
            return SteeringDecision(heading: th, speed: 0.0, freeDist: 0.0,
                                    blocked: true, reason: "boxed_in")
        }
        // hysteresis: during the commit window, keep the previous sector
        // unless the challenger wins by a clear margin
        let reason: String
        if hold > 0 && prevScore > -Double.infinity
            && bestScore - prevScore < switchMargin {
            chosenAng = prev!
            bestFree = prevFree
            hold -= 1
            reason = "hold"
        } else {
            hold = commitTicks
            reason = "steer"
        }
        prev = chosenAng
        let frac = (bestFree - minFree) / max(lookahead - minFree, 1e-6)
        let speed = vmax * max(0.25, Swift.min(1.0, frac))
        return SteeringDecision(heading: chosenAng, speed: speed,
                                freeDist: bestFree, blocked: false,
                                reason: reason)
    }
}
