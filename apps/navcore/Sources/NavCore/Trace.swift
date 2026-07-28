// Trace recording — port of engine trace.py. A trace is one header
// frame plus one frame per tick; schema v1 is the contract between the
// engine, the HTML viewer, and the on-device diagnostic recorder.
//
// Per docs/PORT.md rule 2, golden comparison happens at PARSED-frame
// level, so this writer keeps structured values (TraceValue) instead of
// producing JSON bytes — the Foundation-allowed layers (app, tests)
// serialize. Floats are rounded like Python round(x, 4) before storage.

public indirect enum TraceValue: Equatable, Sendable {
    case double(Double)
    case int(Int)
    case string(String)
    case bool(Bool)
    case array([TraceValue])
    case object([String: TraceValue])
}

/// Python round(x, 4): banker's rounding at 4 decimals, with -0.0
/// normalized to 0.0 (the Python side does the same to keep hashes
/// stable).
public func pyRound4(_ x: Double) -> Double {
    let r = (x * 1e4).rounded(.toNearestOrEven) / 1e4
    return r == 0 ? 0.0 : r
}

func roundedValue(_ v: TraceValue) -> TraceValue {
    switch v {
    case .double(let d):
        return .double(pyRound4(d))
    case .array(let a):
        return .array(a.map(roundedValue))
    case .object(let o):
        return .object(o.mapValues(roundedValue))
    default:
        return v
    }
}

/// Fields that vary run-to-run without the BEHAVIOR changing — excluded
/// from golden comparison, same set as the Python engine.
public let VOLATILE_FIELDS: Set<String> = ["replan_ms"]

public final class TraceWriter {
    public private(set) var header: [String: TraceValue]
    public private(set) var frames: [[String: TraceValue]] = []

    public init(header: [String: TraceValue]) {
        var h = header
        h["type"] = .string("header")
        h["v"] = .int(1)
        self.header = h.mapValues(roundedValue)
    }

    public func frame(_ fields: [String: TraceValue]) {
        var f = fields
        f["type"] = .string("frame")
        frames.append(f.mapValues(roundedValue))
    }

    /// Frames with volatile fields removed — what golden comparison uses.
    public func stableFrames() -> [[String: TraceValue]] {
        frames.map { f in
            f.filter { !VOLATILE_FIELDS.contains($0.key) }
        }
    }
}
