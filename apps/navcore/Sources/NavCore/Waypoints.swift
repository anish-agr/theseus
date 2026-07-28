// Semantic waypoint registry — port of engine waypoints.py: noisy
// detections in, stable named targets out. MERGE (confidence-weighted
// position mean), PROMOTE (with hysteresis), DECAY (observed-but-unseen
// waypoints lose confidence and die). On-device this consumes the
// Vision/Core ML detector at M4.

public final class Waypoint {
    public let uid: String
    public let label: String
    public var pos: Vec
    public var confidence: Double
    public var hits: Int
    public var lastTick: Int
    public var promoted: Bool

    init(uid: String, label: String, pos: Vec, confidence: Double,
         hits: Int, lastTick: Int, promoted: Bool = false) {
        self.uid = uid
        self.label = label
        self.pos = pos
        self.confidence = confidence
        self.hits = hits
        self.lastTick = lastTick
        self.promoted = promoted
    }
}

public final class WaypointRegistry {
    public let mergeRadius: Double
    public let promoteConf: Double
    public let dropConf: Double
    public let missDecay: Double
    public let maxConf: Double
    private var wps: [String: Waypoint] = [:]
    // Python iterates its dict in insertion order (observe_area's
    // returned dead list depends on it); Swift dictionaries don't, so
    // insertion order is tracked explicitly.
    private var order: [String] = []
    private var counter = 0

    public init(mergeRadius: Double = 0.7, promoteConf: Double = 2.5,
                dropConf: Double = 0.25, missDecay: Double = 0.6,
                maxConf: Double = 6.0) {
        self.mergeRadius = mergeRadius
        self.promoteConf = promoteConf
        self.dropConf = dropConf
        self.missDecay = missDecay
        self.maxConf = maxConf
    }

    public var count: Int { wps.count }

    public func get(_ uid: String) -> Waypoint? { wps[uid] }

    public func all() -> [Waypoint] {
        wps.values.sorted { $0.uid < $1.uid }
    }

    /// One detection hit. Returns the (possibly new) waypoint it merged
    /// into.
    @discardableResult
    public func report(label: String, pos: Vec, confidence: Double = 1.0,
                       tick: Int = 0) -> Waypoint {
        var best: Waypoint? = nil
        for wp in all() {
            if wp.label == label && dist(wp.pos, pos) <= mergeRadius {
                if best == nil || dist(wp.pos, pos) < dist(best!.pos, pos) {
                    best = wp
                }
            }
        }
        let target: Waypoint
        if let best {
            target = best
        } else {
            let uid = "\(label)-\(counter)"
            counter += 1
            target = Waypoint(uid: uid, label: label, pos: pos,
                              confidence: 0.0, hits: 0, lastTick: tick)
            wps[uid] = target
            order.append(uid)
        }
        let wOld = target.confidence
        let wNew = max(1e-6, confidence)
        let tot = wOld + wNew
        target.pos = Vec((target.pos.x * wOld + pos.x * wNew) / tot,
                         (target.pos.y * wOld + pos.y * wNew) / tot)
        target.confidence = Swift.min(maxConf, target.confidence + confidence)
        target.hits += 1
        target.lastTick = tick
        if target.confidence >= promoteConf {
            target.promoted = true
        }
        return target
    }

    /// The detector processed a frame covering this area; call report()
    /// for its hits first, then pass those uids here. Every other
    /// waypoint inside the area decays. Returns uids removed.
    @discardableResult
    public func observeArea(center: Vec, radius: Double, tick: Int,
                            seenUids: Set<String> = []) -> [String] {
        var dead: [String] = []
        for uid in order {
            guard let wp = wps[uid] else { continue }
            if seenUids.contains(uid) || dist(wp.pos, center) > radius {
                continue
            }
            wp.confidence -= missDecay
            wp.lastTick = tick
            if wp.confidence < dropConf {
                dead.append(uid)
            }
        }
        for uid in dead {
            wps[uid] = nil
        }
        order.removeAll { wps[$0] == nil }
        return dead
    }

    /// Promoted waypoints, most confident first.
    public func targets() -> [Waypoint] {
        wps.values.filter { $0.promoted }.sorted {
            if $0.confidence != $1.confidence {
                return $0.confidence > $1.confidence
            }
            return $0.uid < $1.uid
        }
    }

    /// Best promoted waypoint with this label ("go to the fridge").
    public func targetFor(_ label: String) -> Waypoint? {
        targets().first { $0.label == label }
    }
}
