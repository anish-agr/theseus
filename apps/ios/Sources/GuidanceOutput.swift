// Voice + haptics for Ariadne mode — the phone-speaker baseline (no
// AirPods required, by design). Speech announces cue changes; haptics
// run a continuous "corridor" texture whose intensity rises as the
// corridor narrows, plus sharp taps for turns.
import AVFoundation
import CoreHaptics
import NavCore

final class GuidanceOutput {
    private let synth = AVSpeechSynthesizer()
    private var hapticEngine: CHHapticEngine?
    private var lastSpokenKind: CueKind?
    private var lastSpeakTime = Date.distantPast

    init() {
        hapticEngine = try? CHHapticEngine()
        try? hapticEngine?.start()
    }

    func update(cue: GuidanceCue?) {
        guard let cue else { return }
        speak(cue)
        buzz(cue)
    }

    private func speak(_ cue: GuidanceCue) {
        let repeatable = Date().timeIntervalSince(lastSpeakTime) > 4.0
        guard cue.kind != lastSpokenKind || repeatable else { return }
        let text: String
        switch cue.kind {
        case .straight:
            text = String(format: "Straight %.0f meters",
                          max(1, cue.distance.rounded()))
        case .turnLeft:
            text = String(format: "Turn left %.0f degrees",
                          abs(cue.angleDeg).rounded())
        case .turnRight:
            text = String(format: "Turn right %.0f degrees",
                          abs(cue.angleDeg).rounded())
        case .arrive:
            text = "You have arrived"
        case .offRoute:
            text = "Off route. Stop."
        }
        lastSpokenKind = cue.kind
        lastSpeakTime = Date()
        let utt = AVSpeechUtterance(string: text)
        utt.rate = 0.55
        synth.speak(utt)
    }

    private func buzz(_ cue: GuidanceCue) {
        guard let hapticEngine else { return }
        // corridor width 1.2 m+ -> gentle; 0.6 m -> strong
        let tightness = Float(
            max(0, min(1, (1.2 - cue.corridor) / 0.6)))
        var events: [CHHapticEvent] = [
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(
                        parameterID: .hapticIntensity,
                        value: 0.2 + 0.6 * tightness),
                    CHHapticEventParameter(
                        parameterID: .hapticSharpness, value: 0.3),
                ],
                relativeTime: 0, duration: 0.15)
        ]
        if cue.kind == .turnLeft || cue.kind == .turnRight {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(
                        parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(
                        parameterID: .hapticSharpness, value: 0.8),
                ],
                relativeTime: 0))
        }
        if let pattern = try? CHHapticPattern(events: events,
                                              parameters: []),
           let player = try? hapticEngine.makePlayer(with: pattern) {
            try? player.start(atTime: 0)
        }
    }
}
