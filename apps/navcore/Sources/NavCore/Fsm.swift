// Navigation state machine — port of engine fsm.py.
//
// One explicit transition table instead of booleans scattered across
// callbacks: on-device, ARKit delegate callbacks, the planner actor and
// the UI all poke at navigation state concurrently, and "which mode are
// we actually in" must have exactly one answer. Illegal transitions
// throw instead of being silently ignored; callers can ask can(_:).
//
// TRACKING_LOST is special-cased: it may fire from ANY active state,
// parks the machine in RELOCALIZING and remembers where it was, so
// TRACKING_RECOVERED resumes seamlessly.

public enum NavState: String, Sendable, CaseIterable {
    case idle = "IDLE"
    case mapping = "MAPPING"            // user sweeps the space
    case planning = "PLANNING"          // a route is being (re)computed
    case guiding = "GUIDING"            // following cues (Ariadne mode)
    case walking = "WALKING"            // free-roam steering, no destination
    case blocked = "BLOCKED"            // no route right now; waiting
    case arrived = "ARRIVED"
    case relocalizing = "RELOCALIZING"  // tracking lost; frame unreliable
}

public enum NavEvent: String, Sendable, CaseIterable {
    case scanStarted = "SCAN_STARTED"
    case mapReady = "MAP_READY"
    case goalSet = "GOAL_SET"
    case planReady = "PLAN_READY"
    case planFailed = "PLAN_FAILED"
    case routeBlocked = "ROUTE_BLOCKED"
    case offRoute = "OFF_ROUTE"
    case arrivedEvt = "ARRIVED_EVT"
    case walkToggled = "WALK_TOGGLED"
    case retry = "RETRY"
    case stop = "STOP"
    case trackingLost = "TRACKING_LOST"
    case trackingRecovered = "TRACKING_RECOVERED"
}

public struct IllegalTransition: Error, Sendable {
    public let state: NavState
    public let event: NavEvent
}

private let TABLE: [NavState: [NavEvent: NavState]] = [
    .idle: [.scanStarted: .mapping, .goalSet: .planning,
            .walkToggled: .walking],
    .mapping: [.mapReady: .idle, .goalSet: .planning, .stop: .idle],
    .planning: [.planReady: .guiding, .planFailed: .blocked, .stop: .idle],
    .guiding: [.routeBlocked: .planning, .offRoute: .planning,
               .goalSet: .planning, .arrivedEvt: .arrived,
               .walkToggled: .walking, .stop: .idle],
    .walking: [.walkToggled: .idle, .goalSet: .planning,
               .routeBlocked: .blocked, .stop: .idle],
    .blocked: [.retry: .planning, .planReady: .guiding,
               .goalSet: .planning, .stop: .idle],
    .arrived: [.goalSet: .planning, .walkToggled: .walking, .stop: .idle],
]

public final class StateMachine {
    public private(set) var state: NavState
    private var resume: NavState?
    public private(set) var history: [(NavState, NavEvent, NavState)] = []

    public init(initial: NavState = .idle) {
        self.state = initial
    }

    public func can(_ event: NavEvent) -> Bool {
        if event == .trackingLost {
            return state != .idle && state != .relocalizing
        }
        if event == .trackingRecovered {
            return state == .relocalizing
        }
        return TABLE[state]?[event] != nil
    }

    @discardableResult
    public func step(_ event: NavEvent) throws -> NavState {
        let old = state
        if event == .trackingLost {
            if !can(event) {
                throw IllegalTransition(state: old, event: event)
            }
            resume = old
            state = .relocalizing
        } else if event == .trackingRecovered {
            if !can(event) {
                throw IllegalTransition(state: old, event: event)
            }
            state = resume ?? .idle
            resume = nil
        } else {
            guard let nxt = TABLE[old]?[event] else {
                throw IllegalTransition(state: old, event: event)
            }
            state = nxt
        }
        history.append((old, event, state))
        return state
    }
}
