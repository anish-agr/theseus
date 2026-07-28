// Main screen: AR camera with world overlays, live minimap, guidance
// banner with the turn arrow, and the mode bar.
import NavCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: NavEngine
    @State private var sessionManager = ARSessionManager()
    @State private var guidanceOutput = GuidanceOutput()
    @State private var showShare = false

    var body: some View {
        ZStack {
            ARViewContainer(sessionManager: sessionManager)
                .ignoresSafeArea()
                .onAppear { sessionManager.engine = engine }

            VStack {
                banner
                if engine.trackingLimited {
                    Text("Tracking limited — move the phone slowly")
                        .font(.footnote)
                        .padding(6)
                        .background(.red.opacity(0.7),
                                    in: Capsule())
                }
                Spacer()
                HStack(alignment: .bottom) {
                    modeBar
                    Spacer()
                    MinimapView()
                        .frame(width: 190, height: 190)
                }
                .padding()
            }
        }
        .onChange(of: engine.cue?.kind) {
            guidanceOutput.update(cue: engine.cue)
        }
        .sheet(isPresented: $showShare) {
            if let text = engine.traceJSONL() {
                ShareSheet(text: text)
            }
        }
    }

    private var banner: some View {
        VStack(spacing: 4) {
            if let cue = engine.cue {
                HStack(spacing: 12) {
                    Image(systemName: arrowName(cue))
                        .font(.system(size: 34, weight: .bold))
                    Text(bannerText(cue))
                        .font(.title3.bold())
                }
                .foregroundColor(cue.kind == .offRoute ? .red : .cyan)
            }
            Text(engine.statusLine)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
            Text("floor \(engine.freeCells) · obstacles "
                 + "\(engine.occupiedCells) · \(engine.fsm.state.rawValue)")
                .font(.caption2.monospaced())
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(10)
        .background(.black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 8)
    }

    private var modeBar: some View {
        VStack(spacing: 10) {
            if engine.mode == .guide {
                Button {
                    engine.stopGuidance()
                } label: {
                    Label("Stop", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Text("Tap the map\nto set a goal")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
            }
            Button {
                engine.toggleAgent()
            } label: {
                Label(engine.mode == .agent ? "Park" : "Agent",
                      systemImage: "figure.walk.motion")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            Button {
                if engine.recording {
                    engine.toggleRecording()
                    showShare = true
                } else {
                    engine.toggleRecording()
                }
            } label: {
                Label(engine.recording ? "Stop rec" : "Record",
                      systemImage: engine.recording
                      ? "record.circle.fill" : "record.circle")
            }
            .buttonStyle(.bordered)
            .tint(engine.recording ? .red : .white)
        }
    }

    private func arrowName(_ cue: GuidanceCue) -> String {
        switch cue.kind {
        case .straight: return "arrow.up"
        case .turnLeft: return "arrow.turn.up.left"
        case .turnRight: return "arrow.turn.up.right"
        case .arrive: return "checkmark.circle.fill"
        case .offRoute: return "exclamationmark.triangle.fill"
        }
    }

    private func bannerText(_ cue: GuidanceCue) -> String {
        switch cue.kind {
        case .straight:
            return String(format: "%.1f m", cue.distance)
        case .turnLeft, .turnRight:
            return String(format: "%.0f°", abs(cue.angleDeg))
        case .arrive:
            return "Arrived"
        case .offRoute:
            return "Off route"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-trace.jsonl")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return UIActivityViewController(activityItems: [url],
                                        applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) {}
}
