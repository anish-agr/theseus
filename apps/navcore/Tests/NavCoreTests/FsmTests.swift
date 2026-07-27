// FSM parity tests — the transition table is enumerated exhaustively
// from Python (every state x event: can() and the resulting state), and
// one scripted journey checks the tracking-lost resume behavior.
import Testing
@testable import NavCore

@Test func everyTransitionMatchesReference() throws {
    for (stateRaw, eventRaw, wantCan, wantNext) in fsmCombos {
        let state = NavState(rawValue: stateRaw)!
        let event = NavEvent(rawValue: eventRaw)!
        let m = StateMachine(initial: state)
        #expect(m.can(event) == wantCan, "\(stateRaw) x \(eventRaw)")
        if wantCan {
            let next = try m.step(event)
            #expect(next.rawValue == wantNext, "\(stateRaw) x \(eventRaw)")
        } else {
            #expect(throws: IllegalTransition.self) {
                try m.step(event)
            }
        }
    }
}

@Test func journeyWithTrackingLossResumes() throws {
    let m = StateMachine()
    for (eventRaw, wantState) in fsmJourney {
        let next = try m.step(NavEvent(rawValue: eventRaw)!)
        #expect(next.rawValue == wantState, "after \(eventRaw)")
    }
    #expect(m.history.count == fsmJourney.count)
}
