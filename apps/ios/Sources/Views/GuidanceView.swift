// Full-screen guidance. Deliberately huge and glanceable: it is used
// while walking, sometimes by someone who can barely see it, so the
// same cue is carried by shape, words, speech and haptics at once.
import NavCore
import SwiftUI

struct GuidanceView: View {
    @EnvironmentObject var engine: NavEngine
    @State private var output = GuidanceOutput()
    @State private var lastSpoken: CueKind?

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: arrowName)
                    .font(.system(size: 120, weight: .bold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(.system(size: 44, weight: .heavy))
                    .minimumScaleFactor(0.5)
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                corridorBar
                    .padding(.horizontal, 40)
                    .padding(.top, 8)

                Spacer()
                HStack {
                    MinimapView().frame(width: 130, height: 130)
                        .opacity(0.9)
                    Spacer()
                    Button(role: .destructive) {
                        engine.clearGuidance()
                    } label: {
                        Label("Stop", systemImage: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
        }
        .onReceive(engine.$cue) { cue in
            output.update(cue: cue)
            if let cue, cue.kind != lastSpoken {
                lastSpoken = cue.kind
                UIAccessibility.post(notification: .announcement,
                                     argument: headline + ". " + detail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
    }

    private var background: some ShapeStyle {
        engine.cue?.kind == .offRoute
            ? AnyShapeStyle(Color.red.opacity(0.35))
            : AnyShapeStyle(Material.ultraThick)
    }

    private var tint: Color {
        switch engine.cue?.kind {
        case .offRoute: return .red
        case .arrive: return .green
        default: return .cyan
        }
    }

    private var arrowName: String {
        switch engine.cue?.kind {
        case .straight: return "arrow.up"
        case .turnLeft: return "arrow.turn.up.left"
        case .turnRight: return "arrow.turn.up.right"
        case .arrive: return "checkmark.circle.fill"
        case .offRoute: return "exclamationmark.triangle.fill"
        case nil: return "hourglass"
        }
    }

    private var headline: String {
        switch engine.cue?.kind {
        case .straight: return "Straight"
        case .turnLeft: return "Turn left"
        case .turnRight: return "Turn right"
        case .arrive: return "Arrived"
        case .offRoute: return "Off route"
        case nil: return "Planning…"
        }
    }

    private var detail: String {
        guard let cue = engine.cue else {
            return engine.statusLine
        }
        switch cue.kind {
        case .turnLeft, .turnRight:
            return String(format: "%.0f°  ·  to %@",
                          abs(cue.angleDeg), engine.goalName)
        case .arrive:
            return engine.goalName
        case .offRoute:
            return "Stop and turn around"
        case .straight:
            let remaining = engine.routeRemainingM ?? cue.distance
            return String(format: "%.1f m  ·  to %@",
                          remaining, engine.goalName)
        }
    }

    /// Corridor width, drawn so a narrowing gap is felt before it is read.
    private var corridorBar: some View {
        let width = engine.cue?.corridor ?? 0
        let fraction = min(1, max(0.05, width / 1.6))
        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(width < 0.75 ? Color.orange : Color.cyan)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 10)
            Text(String(format: "corridor %.2f m", width))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
