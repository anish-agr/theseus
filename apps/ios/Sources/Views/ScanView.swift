// The camera IS the scanner. Sweep to map; hold the reticle on anything
// (or tap the shutter) to remember it. First launch teaches the moves;
// a Finish flow answers "what now?" — both were missing from the first
// field test and the app read as a dead end.
import ARKit
import NavCore
import SwiftData
import SwiftUI

struct ScanView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Binding var room: Room?
    @Binding var selectedTab: Int
    @AppStorage("scanCoachSeen") private var coachSeen = false
    @StateObject private var session = ARSessionManager()
    @StateObject private var capture = ObjectCapture()
    @StateObject private var voice = VoiceControl()
    @ObservedObject private var ai = AIService.shared
    @Query private var allThings: [Thing]
    @Query private var spots: [StorageSpot]
    @Query(sort: \Room.lastScannedAt, order: .reverse)
    private var rooms: [Room]
    /// Fewer overlays = a camera you can actually read. Default ON:
    /// shutter + top bar + lock brackets only (field test 6: "scan is
    /// the only UI not clean").
    @AppStorage("scanMinimalUI") private var minimalUI = true
    /// The scanner shows a calm start page until you actually start —
    /// no live camera, no overlays, no heat (field test 6).
    @State private var scanning = false
    @State private var newRoomName = ""
    @State private var card: CapturedObject?
    @State private var cardThing: Thing?
    @State private var cardWasNew = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var saveNotice: String?
    @State private var showCoach = false
    @State private var showSummary = false
    // lens: look, don't save
    @State private var lensOn = false
    @State private var lensResult: LensResult?
    @State private var lensAI: AIIdentification?
    @State private var lensBusy = false
    @State private var voiceNotice: String?
    @State private var openedSpotID: UUID?

    var body: some View {
        ZStack {
            ARViewContainer(sessionManager: session, thingPins: pins)
                .ignoresSafeArea()

            // the lock-on frame: what a capture would actually save —
            // corner brackets, not a box claiming precision the
            // saliency model doesn't have. Absent = no lock = the
            // dwell won't arm.
            GeometryReader { _ in
                if scanning, let box = session.subjectBox,
                   room != nil {
                    LockBrackets()
                        .stroke(lensOn ? Color.brandDot
                                       : Color.brandThread,
                                style: StrokeStyle(lineWidth: 3,
                                                   lineCap: .round))
                        .shadow(color: (lensOn ? Color.brandDot
                                              : Color.brandThread)
                            .opacity(0.5), radius: 5)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .animation(.easeInOut(duration: 0.2),
                                   value: box)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if scanning {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if voice.listening || voiceNotice != nil
                        || voice.problem != nil {
                        voiceChip
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                    }
                    if let lensResult {
                        lensCard(lensResult)
                            .padding(.horizontal)
                            .transition(.move(edge: .bottom).combined(
                                with: .opacity))
                    }
                    if let card {
                        captureCard(card)
                            .padding(.horizontal)
                            .transition(.move(edge: .bottom).combined(
                                with: .opacity))
                    }
                    if engine.locateTarget != nil {
                        LocateBar(active: selectedTab == 1)
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                    }
                    HStack(alignment: .bottom) {
                        if !minimalUI { hintBubble }
                        Spacer()
                        VStack(spacing: 10) {
                            if !minimalUI {
                                lensButton
                                micButton
                            }
                            shutterButton
                            if !minimalUI {
                                MinimapView(pins: minimapPins)
                                    .frame(width: 140, height: 140)
                            }
                        }
                    }
                    .padding()
                }
            }

            if !scanning { startPage }
            if scanning, showCoach || (!coachSeen && room != nil) {
                coachOverlay
            }
        }
        // camera-first: the tab bar keeps its icons but loses its
        // slab, fading into the feed instead of sitting on it
        .toolbarBackground(.hidden, for: .tabBar)
        .animation(.spring(duration: 0.3), value: card != nil)
        .animation(.spring(duration: 0.3),
                   value: engine.locateTarget != nil)
        .onAppear {
            session.engine = engine
            session.capture = capture
            voice.onCommand = { handleVoice($0) }
            syncRoom()
            // the camera stays dark until Start is tapped; the AR
            // view may finish initializing after onAppear, so the
            // pause lands just behind it
            if !scanning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !scanning, !engine.isGuiding {
                        session.pauseSession()
                    }
                }
            }
        }
        .onChange(of: room?.id) { _, _ in syncRoom() }
        // thermal discipline: the camera pipeline runs ONLY while a
        // scan is actually live and on screen (or guidance is) —
        // otherwise it cooks the phone into throttling within minutes
        .onChange(of: selectedTab) { _, tab in
            if tab == 1, scanning {
                session.resumeSession()
            } else if tab != 1, !engine.isGuiding {
                persist()
                session.pauseSession()
            }
        }
        .onChange(of: engine.isGuiding) { _, guiding in
            if guiding {
                session.resumeSession()
            } else if selectedTab != 1 || !scanning {
                session.pauseSession()
            }
        }
        // the summary sheet (and its AI pass) deserves a cool phone
        .onChange(of: showSummary) { _, open in
            if open {
                session.pauseSession()
            } else if scanning, selectedTab == 1 {
                session.resumeSession()
            }
        }
        // onReceive rather than onChange: CapturedObject carries a
        // UIImage and is deliberately not Equatable
        .onReceive(session.$pendingCapture) { new in
            guard let new else { return }
            // a Theseus QR label is a doorway, not an object: pointing
            // the camera at a box label opens the box
            if let code = new.recognition.barcode,
               code.hasPrefix("theseus://spot/"),
               let id = UUID(uuidString: String(
                code.dropFirst("theseus://spot/".count))) {
                session.pendingCapture = nil
                openedSpotID = id
                UIImpactFeedbackGenerator(style: .medium)
                    .impactOccurred()
                return
            }
            // lens mode looks things up instead of saving them
            if lensOn {
                session.pendingCapture = nil
                lensAI = nil
                lensResult = LensResult.lookup(new, things: allThings,
                                               spots: spots)
                UIImpactFeedbackGenerator(style: .light)
                    .impactOccurred()
                return
            }
            guard let room else { return }
            let thing = capture.commit(new, room: room, context: context)
            room.lastScannedAt = Date()
            card = new
            cardThing = thing
            // hits == 1 means commit CREATED it (a merge increments);
            // only a fresh thing can be un-saved from the card
            cardWasNew = thing.hits == 1
            draftName = thing.displayName
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.pendingCapture = nil
            // Cascade order: classifier → lookalike → AI →
            // text on the object → ask. The AI step runs here, after
            // commit, because it's async — it quietly upgrades weak
            // auto-names and only ever asks the user when IT failed
            // too.
            // NOTHING interrupts a scan (field test 6): no naming
            // popups, no live AI calls. The ✨ batch pass names
            // everything properly afterwards; Rename on the card is
            // there for the impatient.
            autoDismissCard()
        }
        .onDisappear(perform: persist)
        .onChange(of: scenePhase) { _, phase in
            // the map must survive a phone call or app switch mid-scan
            if phase == .background { persist() }
        }
        .alert("Name it", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            if let text = cardThing?.recognizedText, !text.isEmpty {
                Button("Use \"\(text.prefix(20))\"") {
                    applyName(String(text.prefix(28)))
                }
            }
            Button("Save") { applyName(draftName) }
            if cardWasNew {
                Button("Don't save this", role: .destructive) {
                    discardCapture()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showSummary) {
            ScanSummarySheet(room: room, selectedTab: $selectedTab,
                             onEndScan: { endScan() })
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $openedSpotID) { id in
            SpotByIDSheet(id: id)
        }
    }

    // ---- pieces ----------------------------------------------------------

    private var pins: [(id: UUID, x: Double, y: Double, height: Double,
                        highlighted: Bool)] {
        let target = engine.locateTarget?.thingID
        // hasPosition filter: itemized box contents have no pin and
        // must not render a marker at the grid origin
        return (room?.things ?? []).filter(\.hasPosition).map {
            ($0.id, $0.positionX, $0.positionY, $0.heightM,
             $0.id == target)
        }
    }

    private var minimapPins: [(x: Double, y: Double, highlighted: Bool)] {
        let target = engine.locateTarget?.thingID
        return (room?.things ?? []).filter(\.hasPosition).map {
            ($0.positionX, $0.positionY, $0.id == target)
        }
    }

    /// The calm front door: pick or create a room, then Start. No
    /// camera, no overlays, no heat until you mean it.
    private var startPage: some View {
        VStack(spacing: 20) {
            Spacer()
            ThreadLogoView()
                .frame(width: 90, height: 90)
            Text("Scan a room")
                .font(.title.bold())
            Text("Sweep the floor, point at things, and the room "
                 + "becomes part of your home's memory.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 10) {
                ForEach(rooms.prefix(4)) { candidate in
                    Button {
                        room = candidate
                    } label: {
                        HStack {
                            Image(systemName: room?.id == candidate.id
                                  ? "circle.inset.filled" : "circle")
                                .foregroundStyle(Color.brandThread)
                            Text(candidate.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(candidate.things.count) things")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(.thinMaterial,
                                    in: RoundedRectangle(
                                        cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    TextField("New room — \"Bedroom\"…",
                              text: $newRoomName)
                        .padding(12)
                        .background(.thinMaterial,
                                    in: RoundedRectangle(
                                        cornerRadius: 12))
                    Button("Create") {
                        let name = newRoomName.trimmingCharacters(
                            in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let created = Room(name: name)
                        context.insert(created)
                        room = created
                        newRoomName = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24)

            Button {
                startScan()
            } label: {
                Text(room == nil
                     ? "Pick a room first"
                     : "Start scanning \(room?.name ?? "")")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(room == nil)
            .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color.brandIndigo,
                                    Color.brandIndigoDeep],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private func startScan() {
        guard room != nil else { return }
        syncRoom()
        session.resumeSession()
        scanning = true
    }

    private func endScan() {
        persist()
        session.pauseSession()
        scanning = false
    }

    /// The one control that matters: capture. The dwell ring lives on
    /// it now — the old center reticle is gone (field test 6).
    private var shutterButton: some View {
        Button {
            session.captureNow()
        } label: {
            ZStack {
                Circle().fill(.white.opacity(0.25))
                    .frame(width: 62, height: 62)
                Circle()
                    .trim(from: 0, to: capture.dwellProgress)
                    .stroke(lensOn ? Color.brandDot
                                   : Color.brandThread,
                            style: StrokeStyle(lineWidth: 4,
                                               lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 62, height: 62)
                // no loading state on capture (field test 7): the
                // save happens in the background and the card slides
                // up when it's ready — the button just stays a button
                Circle().fill(.white)
                    .frame(width: 48, height: 48)
            }
        }
        .disabled(capture.busy || !session.floorFound)
        .opacity(session.floorFound ? 1 : 0.4)
        .accessibilityLabel("Capture what the camera is pointing at")
    }

    /// Lens: point at anything and ask, without saving. Recognizes
    /// YOUR stuff by its visual fingerprint; the AI answers for
    /// everything else.
    private var lensButton: some View {
        Button {
            lensOn.toggle()
            if !lensOn { lensResult = nil }
        } label: {
            Image(systemName: lensOn
                  ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(lensOn
                            ? AnyShapeStyle(Color.brandThread)
                            : AnyShapeStyle(.ultraThinMaterial),
                            in: Circle())
                .foregroundStyle(lensOn ? .black : .white)
        }
        .accessibilityLabel(lensOn
                            ? "Lens on — captures identify instead "
                            + "of saving"
                            : "Turn on the lens")
    }

    private var micButton: some View {
        Button {
            voice.toggle()
        } label: {
            Image(systemName: voice.listening ? "mic.fill" : "mic")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(voice.listening
                            ? AnyShapeStyle(Color.brandDot)
                            : AnyShapeStyle(.ultraThinMaterial),
                            in: Circle())
                .foregroundStyle(voice.listening ? .black : .white)
        }
        .accessibilityLabel(voice.listening
                            ? "Listening — tap to finish"
                            : "Voice command")
    }

    private var voiceChip: some View {
        HStack(spacing: 8) {
            if voice.listening {
                Circle().fill(Color.brandDot)
                    .frame(width: 8, height: 8)
                Text(voice.transcript.isEmpty
                     ? "Listening… \"mark this\", \"what is this\", "
                       + "\"find my keys\""
                     : voice.transcript)
                    .font(.footnote)
            } else if let problem = voice.problem {
                Text(problem).font(.footnote)
            } else if let voiceNotice {
                Text(voiceNotice).font(.footnote)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6),
                    in: Capsule())
        .foregroundStyle(.white)
        .task(id: voiceNotice) {
            guard voiceNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            voiceNotice = nil
            voice.problem = nil
        }
    }

    // ---- lens ------------------------------------------------------------

    private func lensCard(_ result: LensResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let match = result.match,
               let thumb = Store.loadThumb(match.id) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let image = result.captured.recognition.image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                if let match = result.match {
                    Text(match.displayName).font(.headline)
                    Text(lensDetail(match, spotName: result.spotName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let lensAI {
                    Text(lensAI.name).font(.headline)
                    Text(lensAI.summary
                         + (lensAI.estimatedValue.map {
                            " · ~" + currencyShort($0)
                                + " " + lensAI.valueNote
                         } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    Text(lensGuess(result)).font(.headline)
                    Text("Not something you've saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let match = result.match, match.hasPosition,
                       let matchRoom = match.room {
                        Button("Find it") {
                            room = matchRoom
                            engine.makeActive(matchRoom)
                            engine.locateTarget = LocateTarget(
                                thingID: match.id,
                                name: match.displayName,
                                x: match.positionX, y: match.positionY)
                            lensResult = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if result.match == nil, lensAI == nil,
                       ai.isConfigured {
                        Button {
                            askLensAI(result)
                        } label: {
                            if lensBusy {
                                ThreadLoadingView(size: 20)
                            } else {
                                Text("Ask AI")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(lensBusy)
                    }
                    if result.match == nil {
                        Button("Save it") {
                            saveFromLens(result)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Spacer()
            Button {
                lensResult = nil
                lensAI = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func lensDetail(_ match: Thing,
                            spotName: String?) -> String {
        var parts: [String] = []
        if let spotName {
            parts.append("lives in \(spotName)")
        } else if let matchRoom = match.room {
            parts.append("usually in \(matchRoom.name)")
        }
        if let price = match.price {
            parts.append(currencyShort(price))
        }
        if let serial = match.serialNumber {
            parts.append("SN \(serial)")
        }
        if let until = match.warrantyUntil, until > Date() {
            parts.append("warranty until "
                + until.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? "Saved in your inventory"
            : parts.joined(separator: " · ")
    }

    private func lensGuess(_ result: LensResult) -> String {
        let label = result.captured.recognition.label
        return label.isEmpty ? "Hmm — not sure" : "Looks like: \(label)"
    }

    private func askLensAI(_ result: LensResult) {
        guard let image = result.captured.recognition.image else {
            return
        }
        lensBusy = true
        Task {
            defer { lensBusy = false }
            lensAI = try? await ai.identify(
                image: image,
                hint: result.captured.recognition.text.isEmpty
                    ? nil
                    : "Text visible on it: "
                        + result.captured.recognition.text)
            if lensAI == nil {
                voiceNotice = "The AI couldn't answer — check the key "
                    + "in Settings."
            }
        }
    }

    /// "Actually, remember this" — lens → inventory without re-aiming.
    private func saveFromLens(_ result: LensResult) {
        guard let room else { return }
        let thing = capture.commit(result.captured, room: room,
                                   context: context)
        if let lensAI {
            thing.displayName = lensAI.name
            thing.userNamed = true
            thing.category = lensAI.category
            thing.aiSummary = lensAI.summary
            if let value = lensAI.estimatedValue {
                thing.price = value
                thing.priceSource = "ai"
            }
            SpotlightIndex.index(thing)
        }
        lensResult = nil
        self.lensAI = nil
        saveNotice = "Saved \"\(thing.displayName)\""
    }

    private func currencyShort(_ v: Double) -> String {
        v.formatted(.currency(
            code: Locale.current.currency?.identifier ?? "USD")
            .precision(.fractionLength(0)))
    }

    // ---- voice -----------------------------------------------------------

    private func handleVoice(_ raw: String) {
        let text = raw.lowercased()
        voiceNotice = nil
        if text.contains("what is this") || text.contains("what's this")
            || text.contains("whats this") {
            lensOn = true
            session.captureNow()
        } else if text.contains("mark this")
            || text.contains("save this")
            || text.contains("remember this")
            || text.contains("capture") {
            lensOn = false
            session.captureNow()
        } else if let query = findQuery(in: text) {
            voiceFind(query)
        } else {
            voiceNotice = "Try: \"mark this\" · \"what is this\" · "
                + "\"find my keys\""
        }
    }

    private func findQuery(in text: String) -> String? {
        let prefixes = ["take me to", "where is my", "where are my",
                        "where is the", "where is", "where are",
                        "find my", "find the", "find", "locate"]
        for prefix in prefixes {
            if let range = text.range(of: prefix) {
                let q = text[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                if !q.isEmpty { return String(q) }
            }
        }
        return nil
    }

    private func voiceFind(_ query: String) {
        let scored = allThings
            .compactMap { thing -> (Thing, Double)? in
                SmartSearch.score(query: query, thing: thing)
                    .map { (thing, $0) }
            }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first?.0 else {
            voiceNotice = "Nothing called \"\(query)\" saved yet"
            return
        }
        if best.hasPosition, let bestRoom = best.room {
            room = bestRoom
            engine.makeActive(bestRoom)
            engine.locateTarget = LocateTarget(
                thingID: best.id, name: best.displayName,
                x: best.positionX, y: best.positionY)
            voiceNotice = "Green beacon: \(best.displayName)"
        } else if let spotID = best.storageID,
                  let spot = spots.first(where: { $0.id == spotID }) {
            voiceNotice = "\(best.displayName) is in \(spot.name)"
        } else {
            voiceNotice = "\(best.displayName) is saved but has no "
                + "pin yet"
        }
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
                coverageBadge
                Button {
                    showCoach = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.body)
                }
                .accessibilityLabel("How to scan")
                Button("Finish") {
                    persist()
                    showSummary = true
                }
                .font(.subheadline.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(engine.scanComplete
                      ? .green : Color.brandThread)
                // the plain way OUT — ends the scan and goes Home;
                // the Scan tab returns to its start page
                Button {
                    endScan()
                    selectedTab = 0
                } label: {
                    Image(systemName: "house")
                        .font(.body)
                }
                .accessibilityLabel("End scan and go Home")
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

    /// "Done" is a state; progress is AREA. A percentage — even a
    /// massaged one — always looks stuck at some number (field tests
    /// 1 and 3); square metres only ever grow.
    private var coverageBadge: some View {
        Group {
            if engine.scanComplete {
                HStack(spacing: 5) {
                    Circle().fill(Color.brandDot)
                        .frame(width: 9, height: 9)
                    Text("Complete")
                }
                .font(.caption.bold())
                .foregroundStyle(.green)
            } else {
                Text(String(format: "%.0f m² mapped",
                            engine.floorAreaM2))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var hintBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let saveNotice {
                HStack(spacing: 6) {
                    SuccessDot(size: 10)
                    Text(saveNotice)
                }
                .font(.caption)
                .foregroundStyle(.green)
            }
            Label(capture.hint.isEmpty ? engine.scanHint : capture.hint,
                  systemImage: engine.scanComplete
                  ? "smallcircle.filled.circle" : "wand.and.rays")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(10)
        .background(.black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 200, alignment: .leading)
        .task(id: saveNotice) {
            guard saveNotice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            saveNotice = nil
        }
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
            if cardWasNew {
                Button {
                    discardCapture()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(.red)
                .accessibilityLabel("Don't save this")
            }
            Button("Rename") { renaming = true }
                .buttonStyle(.bordered).controlSize(.small)
            Button {
                card = nil
            } label: {
                Image(systemName: "arrow.down.right.circle")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .accessibilityLabel("Keep it")
        }
        .padding(10)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// "Don't save this item" — deletes the thing the capture just
    /// created. (A capture that MERGED into something you already had
    /// doesn't offer this: deleting history to undo a glance would be
    /// worse.)
    private func discardCapture() {
        if cardWasNew, let thing = cardThing {
            Store.deleteThingBlobs(thing.id)
            context.delete(thing)
        }
        card = nil
        cardThing = nil
        renaming = false
    }

    private func sizeLine(_ c: CapturedObject) -> String {
        guard c.widthM > 0 else {
            return "saved — size unknown, re-look from closer to measure"
        }
        let w = c.widthM * 100
        let h = c.physicalHeightM * 100
        let size = (w >= 100 || h >= 100)
            ? String(format: "%.2f × %.2f m", c.widthM, c.physicalHeightM)
            : String(format: "%.0f × %.0f cm", w, h)
        let quality = c.sizeConfidence > 0.5 ? "" : " (rough)"
        return size + quality
            + String(format: " · %.1f m away", c.depthM)
    }

    // ---- overlays --------------------------------------------------------

    private var coachOverlay: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How to scan")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)
            coachRow(icon: "arrow.left.and.right",
                     title: "Sweep the floor first",
                     text: "Point down-and-ahead and pan slowly until "
                     + "the map in the corner starts filling in.")
            coachRow(icon: "figure.walk",
                     title: "Walk the edges",
                     text: "Keep the camera where the floor meets the "
                     + "walls. Follow the hint — it points at whatever "
                     + "is still unmapped.")
            coachRow(icon: "arrow.down.forward.circle",
                     title: "Tilt down over furniture",
                     text: "Aim across tabletops and chairs so they "
                     + "become obstacles on the map, not empty space.")
            coachRow(icon: "circle.circle",
                     title: "Point at things to save them",
                     text: "Hold the circle on any object for a second "
                     + "— photo, size and location are remembered. The "
                     + "white button captures instantly.")
            Button {
                coachSeen = true
                showCoach = false
            } label: {
                Text("Got it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 22))
        .padding(24)
    }

    private func coachRow(icon: String, title: String,
                          text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.brandThread)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // ---- actions ---------------------------------------------------------

    private func applyName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let thing = cardThing else { return }
        thing.displayName = trimmed
        thing.userNamed = true
        SpotlightIndex.index(thing)
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

    /// Point engine + AR session at the selected room. No-ops when the
    /// room is already active, so tab switches never reset tracking.
    private func syncRoom() {
        guard let room else { return }
        engine.makeActive(room)
        session.activateRoom(
            id: room.id,
            worldMap: room.hasWorldMap
                ? Store.loadWorldMap(room.id) : nil)
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
            // the room may have been deleted while ARKit serialized
            if !room.isDeleted, ok {
                room.hasWorldMap = true
            }
        }
    }
}

// ---- lock-on brackets ----------------------------------------------------

/// Four corner brackets — the "targeting" idiom. Honest about being
/// approximate in a way a tight box is not.
struct LockBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.22
        var p = Path()
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

// ---- lens lookup ---------------------------------------------------------

/// What the lens saw: the capture, plus the saved thing it matched (by
/// visual fingerprint, anywhere in the home) and where that thing
/// lives. No match + no AI = "looks like: <classifier guess>".
struct LensResult {
    let captured: CapturedObject
    let match: Thing?
    let spotName: String?

    static func lookup(_ captured: CapturedObject, things: [Thing],
                       spots: [StorageSpot]) -> LensResult {
        var best: Thing?
        var bestDistance = Float.greatestFiniteMagnitude
        if let print = captured.recognition.featurePrint {
            for thing in things {
                guard let fp = thing.featurePrint,
                      let d = VisionPipeline.distance(fp, print) else {
                    continue
                }
                if d < bestDistance {
                    bestDistance = d
                    best = thing
                }
            }
        }
        // between the merge threshold (0.6, same object re-look) and
        // the name-borrow threshold (0.75): "recognize" needs more
        // confidence than borrowing a name, less than merging pins
        let match = bestDistance < 0.68 ? best : nil
        var spotName: String?
        if let id = match?.storageID {
            spotName = spots.first { $0.id == id }?.name
        }
        return LensResult(captured: captured, match: match,
                          spotName: spotName)
    }
}

// ---- after the scan ------------------------------------------------------

/// "What now?" — the screen the first field test was missing. Saves are
/// already done by the time this appears; it exists to show the result
/// and hand the user somewhere useful to go.
struct ScanSummarySheet: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.dismiss) private var dismiss
    let room: Room?
    @Binding var selectedTab: Int
    /// Every exit except "Keep scanning" ends the scan — the Scan tab
    /// goes back to its start page instead of a live camera.
    var onEndScan: () -> Void = {}
    @State private var showAIReview = false

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(.tertiary).frame(width: 36, height: 5)
                .padding(.top, 8)
            Text(room?.name ?? "Room")
                .font(.title2.bold())
            MinimapView(pins: pins)
                .frame(height: 190)
                .padding(.horizontal)

            HStack(spacing: 0) {
                stat(value: String(format: "%.0f m²",
                                   engine.floorAreaM2),
                     label: "floor mapped")
                Divider().frame(height: 34)
                stat(value: "\(room?.things.count ?? 0)",
                     label: "things saved")
                Divider().frame(height: 34)
                stat(value: engine.scanComplete ? "●" : "…",
                     label: engine.scanComplete
                     ? "complete" : "keep sweeping")
            }
            .padding(.vertical, 6)

            Button {
                showAIReview = true
            } label: {
                Label("Identify what you scanned with AI",
                      systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Button {
                onEndScan()
                selectedTab = 2
                dismiss()
            } label: {
                Label("Done — see everything I saved",
                      systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            Button("Keep scanning") { dismiss() }
                .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showAIReview) {
            NavigationStack { AIReviewView() }
        }
    }

    private var pins: [(x: Double, y: Double, highlighted: Bool)] {
        (room?.things ?? []).filter(\.hasPosition)
            .map { ($0.positionX, $0.positionY, false) }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// ---- locate-in-camera ----------------------------------------------------

/// The "find my thing" experience: the camera stays up, the item's pin
/// glows green in AR, and this bar tracks live distance and direction
/// with haptic ticks that quicken as you close in. Turn-by-turn stays
/// one tap away for when a route actually helps.
struct LocateBar: View {
    @EnvironmentObject var engine: NavEngine
    /// False when the Scan tab isn't front — the geiger haptics must
    /// never tick from a background tab (field test 2: "it keeps
    /// doing the haptic thing even when you're not scanning").
    var active: Bool = true
    @State private var lastTick = Date.distantPast
    /// Route-aware aim: heading toward a point ~0.75 m down an actual
    /// walkable path, and walking distance — a straight-line arrow
    /// "just points you into a wall" (field test 3). Straight line is
    /// only the fallback when no route exists yet.
    @State private var routeHint: (heading: Double,
                                   distanceM: Double)?
    @State private var lastPlanAt = Date.distantPast
    private static let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        guard let target = engine.locateTarget else {
            return AnyView(EmptyView())
        }
        let dx = target.x - engine.pose.x
        let dy = target.y - engine.pose.y
        let straight = (dx * dx + dy * dy).squareRoot()
        let distance = routeHint?.distanceM ?? straight
        let aim = routeHint?.heading ?? atan2(dy, dx)
        let rel = wrapAngle(aim - engine.pose.heading)

        return AnyView(
            HStack(spacing: 12) {
                ThingThumbnail(thingID: target.thingID)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.headline).lineLimit(1)
                    Text(distance < 0.8
                         ? "Right here — look around"
                         : String(format: "%.1f m away", distance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "location.north.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .rotationEffect(.radians(-rel))
                    .accessibilityLabel(directionWords(rel))
                Button {
                    engine.startGuidance(
                        to: Vec(target.x, target.y),
                        name: target.name)
                } label: {
                    Image(systemName: "figure.walk")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Turn-by-turn guidance")
                Button {
                    engine.locateTarget = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Stop locating")
            }
            .padding(10)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: engine.pose.x) { _, _ in
                tick(distance: distance)
                // replan the aim at most once a second — cheap A*
                if active,
                   Date().timeIntervalSince(lastPlanAt) > 1.0 {
                    lastPlanAt = Date()
                    routeHint = engine.locateHint(
                        to: Vec(target.x, target.y))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(target.name), \(String(format: "%.1f", distance)) "
                + "meters, \(directionWords(rel))")
        )
    }

    /// Geiger-counter haptics: period shrinks as distance does.
    private func tick(distance: Double) {
        guard active else { return }
        let period = max(0.25, min(1.6, distance * 0.35))
        guard Date().timeIntervalSince(lastTick) > period else { return }
        lastTick = Date()
        let strength = distance < 1.5 ? 0.9 : 0.5
        Self.haptic.impactOccurred(intensity: strength)
    }

    private func directionWords(_ rel: Double) -> String {
        let deg = rel * 180 / .pi
        switch deg {
        case -30...30: return "ahead"
        case 30...110: return "to your left"
        case -110...(-30): return "to your right"
        default: return "behind you"
        }
    }
}
