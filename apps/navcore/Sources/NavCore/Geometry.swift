// Geometry primitives — line-by-line port of engine geometry.py.
//
// Conventions (canonical for the whole project):
// - world units are meters; top-down view, +x right, +y up
// - headings in radians, 0 along +x, counter-clockwise positive
// - a positive bearing error means "turn left"
// - grid cells are (col, row); cell (0, 0) has its corner at the grid
//   origin and its center at origin + cellSize/2
//
// Port rules in force here (docs/PORT.md): keep floating-point operation
// ORDER identical to the Python, wrapAngle stays atan2(sin, cos)
// literally, and no Foundation — trig comes from the platform C library.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import CRT
#endif

public typealias Vec = SIMD2<Double>

public struct Cell: Hashable, Sendable {
    public var x: Int32
    public var y: Int32
    public init(_ x: Int32, _ y: Int32) {
        self.x = x
        self.y = y
    }
}

public let SQRT2: Double = 2.0.squareRoot()
public let INF: Double = .infinity

/// Python's float floor division (a // b), ported from CPython's
/// float_divmod. NOT equivalent to (a / b).rounded(.down): IEEE division
/// rounds the quotient to nearest double FIRST, so 0.5 / 0.05 is exactly
/// 10.0 and flooring it gives 10 — while Python's fmod-based algorithm
/// gives 9. The engine's world_to_cell inherits Python's semantics at
/// cell boundaries; the parity fixtures caught this divergence live.
public func pythonFloorDiv(_ a: Double, _ b: Double) -> Double {
    var mod = fmod(a, b)
    var div = (a - mod) / b
    if mod != 0.0 {
        if (b < 0) != (mod < 0) {
            mod += b
            div -= 1.0
        }
    }
    if div != 0.0 {
        let floordiv = div.rounded(.down)
        if div - floordiv > 0.5 {
            return floordiv + 1.0
        }
        return floordiv
    }
    return Double(signOf: a / b, magnitudeOf: 0.0)
}

public func dist(_ a: Vec, _ b: Vec) -> Double {
    hypot(b.x - a.x, b.y - a.y)
}

/// Wrap any angle to (-pi, pi]. Ported literally — clever fmod-based
/// versions differ from this at ±π (PORT.md landmine 7).
public func wrapAngle(_ a: Double) -> Double {
    atan2(sin(a), cos(a))
}

/// Absolute heading of the vector frm -> to.
public func bearing(from frm: Vec, to: Vec) -> Double {
    atan2(to.y - frm.y, to.x - frm.x)
}

/// Octile distance in cell units: exact shortest 8-connected distance on
/// an empty grid, and an admissible/consistent A* heuristic under a cost
/// model whose cheapest cell cost is 1.0.
public func octile(_ a: Cell, _ b: Cell) -> Double {
    let dx = abs(Int(a.x) - Int(b.x))
    let dy = abs(Int(a.y) - Int(b.y))
    let (lo, hi) = dx < dy ? (dx, dy) : (dy, dx)
    return Double(hi - lo) + SQRT2 * Double(lo)
}

/// Closest point on segment a-b to p, plus the parameter t in [0, 1].
public func projectPointSegment(_ p: Vec, _ a: Vec, _ b: Vec) -> (Vec, Double) {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSq = dx * dx + dy * dy
    if lengthSq <= 1e-12 {
        return (a, 0.0)
    }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq
    t = max(0.0, min(1.0, t))
    return (Vec(a.x + t * dx, a.y + t * dy), t)
}

public func polylineLength(_ pts: [Vec]) -> Double {
    guard pts.count > 1 else { return 0.0 }
    var total = 0.0
    for i in 0..<(pts.count - 1) {
        total += dist(pts[i], pts[i + 1])
    }
    return total
}

/// Walk `ahead` meters along a polyline starting from parameter
/// (segment startI, fraction startT); clamps at the final point.
public func pointAlong(_ pts: [Vec], startI: Int, startT: Double,
                       ahead: Double) -> Vec {
    precondition(!pts.isEmpty, "empty polyline")
    if pts.count == 1 {
        return pts[0]
    }
    let a = pts[startI]
    let b = pts[startI + 1]
    var pos = Vec(a.x + (b.x - a.x) * startT, a.y + (b.y - a.y) * startT)
    var remaining = ahead
    var i = startI
    while true {
        let segEnd = pts[i + 1]
        let d = dist(pos, segEnd)
        if remaining <= d || i == pts.count - 2 {
            if d <= 1e-9 {
                return segEnd
            }
            let f = min(1.0, remaining / d)
            return Vec(pos.x + (segEnd.x - pos.x) * f,
                       pos.y + (segEnd.y - pos.y) * f)
        }
        remaining -= d
        pos = segEnd
        i += 1
    }
}
