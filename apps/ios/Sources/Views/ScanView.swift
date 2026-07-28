// The camera IS the app. Sweep to map; hold the reticle on anything
// for ~1.2 s to remember it. No buttons in the common path.
import ARKit
import NavCore
import SwiftData
import SwiftUI

struct ScanView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Binding var room: Room?
    @StateObject private var session = ARSessionManager()
    @StateObject private var capture = ObjectCapture()
    @State private var card: CapturedObject?
    @State private var cardThing: Thing?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var saveNotice: String?

    var body: some View {
        ZStack {
            ARViewContainer(sessionManager: session, thingPins: pins)
                .ignoresSafeArea()

            reticle

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let card {
                    captureCard(card)
                        .padding(.horizontal)
                        .transition(.move(edge: .bottom).combined(
                            with: .opacity))
                }
                HStack(alignment: .bottom) {
                    hintBubble
                    Spacer()
                    MinimapView()
                        .frame(width: 150, height: 150)
                }
                .padding()
            }
        }
        .animation(.spring(duration: 0.3), value: card != nil)
        .onAppear {
            session.engine = engine
            session.capture = capture
        }
        // onReceive rather than onChange: CapturedObject carries a
        // UIImage and is deliberately not Equatable
        .onReceive(session.$pendingCapture) { new in
            guard let new, let room else { return }
            let thing = capture.commit(new, room: room, context: context)
            room.lastScannedAt = Date()
            card = new
            cardThing = thing
            draftName = thing.displayName
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.pendingCapture = nil
            autoDismissCard()
        }
        .onDisappear(perform: persist)
        .alert("Name it", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            if let text = cardThing?.recognizedText, !text.isEmpty {
                Button("Use \"\(text.prefix(20))\"") {
                    applyName(String(text.prefix(28)))
                }
            }
            Button("Save") { applyName(draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // ---- pieces ----------------------------------------------------------

    private var pins: [(id: UUID, x: Double, y: Double, height: Double)] {
        (room?.things ?? []).map {
            ($0.id, $0.positionX, $0.positionY, $0.heightM)
        }
    }

    private var reticle: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.6), lineWidth: 2)
                .frame(width: 74, height: 74)
            Circle()
                .trim(from: 0, to: capture.dwellProgress)
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 5,
                                                       lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 74, height: 74)
            if capture.busy {
                ProgressView().tint(.cyan)
            } else {
                Circle().fill(.white.opacity(0.85))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel("Aim reticle. Hold steady on an object to "
                            + "remember it.")
    }

    private var topBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text(room?.name ?? "No room selected")
                    .font(.headline)
                Spacer()
                if engine.recording {
                    Label("REC", systemImage: "record.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                Text("\(Int(engine.coverage * 100))% mapped")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(engine.coverage > 0.6
                                     ? .green : .orange)
            }
            if engine.trackingLimited {
                Text(session.trackingState)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.red.opacity(0.75), in: Capsule())
            }
        }
        .padding(10)
        .background(.black.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var hintBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let saveNotice {
                Label(saveNotice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text(capture.hint.isEmpty ? engine.scanHint : capture.hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(8)
        .background(.black.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 190, alignment: .leading)
    }

    private func captureCard(_ captured: CapturedObject) -> some View {
        HStack(spacing: 12) {
            if let image = captured.recognition.image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cardThing?.displayName ?? "Object")
                    .font(.headline).lineLimit(1)
                Text(sizeLine(captured))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") { renaming = true }
                .buttonStyle(.bordered).controlSize(.small)
            Button {
                card = nil
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func sizeLine(_ c: CapturedObject) -> String {
        let w = c.widthM * 100
        let h = c.physicalHeightM * 100
        let size = (w >= 100 || h >= 100)
            ? String(format: "%.2f × %.2f m", c.widthM, c.physicalHeightM)
            : String(format: "%.0f × %.0f cm", w, h)
        let quality = c.sizeConfidence > 0.5 ? "" : " (rough)"
        return size + quality + String(format: " · %.1f m away", c.depthM)
    }

    // ---- actions ---------------------------------------------------------

    private func applyName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let thing = cardThing else { return }
        thing.displayName = trimmed
        thing.userNamed = true
        saveNotice = "Saved \"\(trimmed)\""
        card = nil
    }

    /// The common case is zero taps: the card confirms what happened and
    /// then gets out of the way.
    private func autoDismissCard() {
        let token = card?.worldX
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            if card?.worldX == token, !renaming {
                card = nil
            }
        }
    }

    /// Persist grid + world map when leaving the scanner.
    private func persist() {
        guard let room else { return }
        Store.archiveGrid(room.id)
        try? Store.saveGrid(engine.grid, roomID: room.id)
        room.coverage = engine.coverage
        room.floorAreaM2 = engine.floorAreaM2
        room.lastScannedAt = Date()
        session.saveWorldMap(roomID: room.id) { ok in
            room.hasWorldMap = ok
        }
    }
}
