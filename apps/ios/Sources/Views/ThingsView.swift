// The inventory: everything the app has ever seen, across every room.
// Search matches your own names first, then the classifier's label,
// then any text read off the object — so "NESCAFÉ" finds the jar.
import NavCore
import PhotosUI
import SwiftData
import SwiftUI

struct ThingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Thing.lastSeenAt, order: .reverse) private var things: [Thing]
    @Query private var spots: [StorageSpot]
    @Binding var activeRoom: Room?
    @Binding var selectedTab: Int
    @State private var query = ""
    @State private var filter: Filter = .all

    private func spotName(_ thing: Thing) -> String? {
        guard let id = thing.storageID else { return nil }
        return spots.first { $0.id == id }?.name
    }

    enum Filter: String, CaseIterable {
        case all = "All"
        case missing = "Missing"
        case moved = "Recently moved"
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty && matches.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                           description: Text("Nothing logged matches \"\(query)\"."))
                }
                ForEach(matches) { thing in
                    NavigationLink {
                        ThingDetailView(thing: thing,
                                        activeRoom: $activeRoom,
                                        selectedTab: $selectedTab)
                    } label: {
                        ThingRow(thing: thing, showRoom: true,
                                 spotName: spotName(thing))
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            locate(thing)
                        } label: {
                            Label("Find", systemImage: "location.fill")
                        }
                        .tint(.green)
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Stuff")
            .searchable(text: $query, prompt: "Search everything you own")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        AIReviewView()
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("Identify items with AI")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .overlay {
                if things.isEmpty {
                    ContentUnavailableView(
                        "Nothing logged yet",
                        systemImage: "shippingbox",
                        description: Text("Go to Scan and hold the "
                                          + "reticle on something for a "
                                          + "moment."))
                }
            }
        }
    }

    private var matches: [Thing] {
        let base: [Thing]
        switch filter {
        case .all: base = things
        case .missing: base = things.filter(\.isMissing)
        case .moved:
            base = things.filter { thing in
                thing.sightings.contains {
                    $0.movedSincePrevious
                        && $0.at > Date().addingTimeInterval(-604800)
                }
            }
        }
        guard !query.isEmpty else { return base }
        // forgiving search: "where are my keys", "sofa" -> couch, typos
        return base
            .compactMap { thing -> (Thing, Double)? in
                SmartSearch.score(query: query, thing: thing)
                    .map { (thing, $0) }
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.lastSeenAt > b.0.lastSeenAt
            }
            .map(\.0)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let thing = matches[index]
            Store.deleteThingBlobs(thing.id)
            context.delete(thing)
        }
    }

    @EnvironmentObject private var engine: NavEngine

    private func locate(_ thing: Thing) {
        guard let room = thing.room else { return }
        activeRoom = room
        engine.makeActive(room)
        engine.locateTarget = LocateTarget(
            thingID: thing.id, name: thing.displayName,
            x: thing.positionX, y: thing.positionY)
        selectedTab = 1
    }
}

struct ThingRow: View {
    let thing: Thing
    let showRoom: Bool
    /// Passed by the parent (which already holds the spots query) —
    /// a per-row @Query here made long lists visibly hitch.
    var spotName: String?

    var body: some View {
        HStack(spacing: 12) {
            ThingThumbnail(thingID: thing.id)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(thing.displayName).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    if let spotName {
                        Text("in \(spotName)")
                        Text("·")
                    } else if showRoom, let room = thing.room {
                        Text(room.name)
                        Text("·")
                    }
                    if thing.hasPosition || thing.widthM > 0 {
                        Text(thing.sizeDescription)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if thing.isMissing {
                        Text("missing")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                        Text("·").font(.caption2)
                    }
                    Text(thing.lastSeenAt,
                         format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ThingThumbnail: View {
    let thingID: UUID

    var body: some View {
        if let image = Store.loadThumb(thingID) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: "cube")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ThingDetailView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var thing: Thing
    @Binding var activeRoom: Room?
    @Binding var selectedTab: Int
    @ObservedObject private var ai = AIService.shared
    @State private var renaming = false
    @State private var draft = ""
    @State private var priceDraft = ""
    @State private var receiptPick: PhotosPickerItem?
    @State private var hasReceipt = false
    @State private var estimating = false
    @State private var estimateNote: String?
    @State private var aiError: String?
    @State private var scanningSerial = false
    @State private var serialCandidates: [String] = []
    @State private var hasWarranty = false

    var body: some View {
        List {
            Section {
                ThingThumbnail(thingID: thing.id)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .listRowInsets(EdgeInsets())
            }
            Section {
                LabeledContent("Size") {
                    VStack(alignment: .trailing) {
                        Text(thing.sizeDescription)
                        if thing.sizeConfidence < 0.5 {
                            Text("rough estimate")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                if let room = thing.room {
                    LabeledContent("Room", value: room.name)
                }
                LabeledContent("First seen") {
                    Text(thing.firstSeenAt, format: .dateTime.day().month())
                }
                LabeledContent("Last seen") {
                    Text(thing.lastSeenAt,
                         format: .dateTime.day().month().hour().minute())
                }
                if !thing.recognizedText.isEmpty {
                    LabeledContent("Text on it",
                                   value: thing.recognizedText)
                }
                if let code = thing.barcode {
                    LabeledContent("Barcode", value: code)
                }
                if !thing.autoLabel.isEmpty, thing.userNamed {
                    LabeledContent("Recognised as",
                                   value: thing.autoLabel)
                }
            }
            Section("Value") {
                HStack {
                    Text(Locale.current.currencySymbol ?? "$")
                        .foregroundStyle(.secondary)
                    TextField("What it's worth", text: $priceDraft)
                        .keyboardType(.decimalPad)
                        .onSubmit(savePrice)
                        .onChange(of: priceDraft) { _, _ in savePrice() }
                    if thing.priceSource == "ai" {
                        Text("AI estimate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if ai.isConfigured {
                    Button {
                        estimateValue()
                    } label: {
                        HStack {
                            Label("Estimate value with AI",
                                  systemImage: "sparkle.magnifyingglass")
                            Spacer()
                            if estimating { ThreadLoadingView(size: 24) }
                        }
                    }
                    .disabled(estimating)
                    if let estimateNote {
                        Text(estimateNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                PhotosPicker(selection: $receiptPick,
                             matching: .images) {
                    Label(hasReceipt
                          ? "Replace receipt photo"
                          : "Add receipt photo",
                          systemImage: "doc.text.image")
                }
                if hasReceipt,
                   let receipt = Store.loadReceipt(thing.id) {
                    Image(uiImage: receipt)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            Section("Insurance") {
                if let serial = thing.serialNumber {
                    LabeledContent("Serial") {
                        Text(serial).textSelection(.enabled)
                            .font(.callout.monospaced())
                    }
                }
                Button {
                    scanningSerial = true
                } label: {
                    Label(thing.serialNumber == nil
                          ? "Scan serial number"
                          : "Re-scan serial",
                          systemImage: "number.square")
                }
                Toggle("Warranty", isOn: $hasWarranty)
                    .onChange(of: hasWarranty) { _, on in
                        if on, thing.warrantyUntil == nil {
                            thing.warrantyUntil = Calendar.current.date(
                                byAdding: .year, value: 1, to: Date())
                        } else if !on {
                            thing.warrantyUntil = nil
                            thing.warrantyNote = nil
                        }
                    }
                if hasWarranty {
                    DatePicker(
                        "Expires",
                        selection: Binding(
                            get: { thing.warrantyUntil ?? Date() },
                            set: { thing.warrantyUntil = $0 }),
                        displayedComponents: .date)
                    TextField("Warranty note — provider, terms…",
                              text: Binding(
                                get: { thing.warrantyNote ?? "" },
                                set: {
                                    thing.warrantyNote =
                                        $0.isEmpty ? nil : $0
                                }))
                }
                if let aiError {
                    Text(aiError)
                        .font(.caption)
                        .foregroundStyle(Color.brandDotCool)
                }
            }
            Section {
                if !thing.hasPosition {
                    // itemized box contents have a home, not a pin
                    Label("Lives in storage — see the Storage list",
                          systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        // camera + green beacon + live distance — the
                        // default "find" (turn-by-turn stays one tap
                        // away on the locate bar)
                        guard let room = thing.room else { return }
                        activeRoom = room
                        engine.makeActive(room)
                        engine.locateTarget = LocateTarget(
                            thingID: thing.id, name: thing.displayName,
                            x: thing.positionX, y: thing.positionY)
                        selectedTab = 1
                        dismiss()
                    } label: {
                        Label("Find it", systemImage: "location.fill")
                    }
                }
                Button {
                    draft = thing.displayName
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Store.deleteThingBlobs(thing.id)
                    context.delete(thing)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if thing.sightings.count > 1 {
                Section("History") {
                    ForEach(thing.sightings.sorted { $0.at > $1.at }) { s in
                        HStack {
                            Text(s.at, format: .dateTime.day().month()
                                .hour().minute())
                            Spacer()
                            if s.movedSincePrevious {
                                Text("moved")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .navigationTitle(thing.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let price = thing.price {
                priceDraft = price == price.rounded()
                    ? String(Int(price)) : String(price)
            }
            hasReceipt = Store.hasReceipt(thing.id)
            hasWarranty = thing.warrantyUntil != nil
        }
        .sheet(isPresented: $scanningSerial) {
            CameraSheet { image in
                serialCandidates = Self.serialLike(
                    VisionPipeline.textLines(in: image))
                if serialCandidates.isEmpty {
                    aiError = "No serial-looking text found — get "
                        + "closer to the label."
                }
            }
        }
        .confirmationDialog("Which line is the serial?",
                            isPresented: Binding(
                                get: { !serialCandidates.isEmpty },
                                set: { if !$0 { serialCandidates = [] } })
        ) {
            ForEach(serialCandidates, id: \.self) { candidate in
                Button(candidate) {
                    thing.serialNumber = candidate
                    serialCandidates = []
                }
            }
            Button("None of these", role: .cancel) {
                serialCandidates = []
            }
        }
        .onChange(of: receiptPick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(
                    type: Data.self) {
                    Store.saveReceipt(data, thingID: thing.id)
                    hasReceipt = true
                }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Save") {
                let trimmed = draft.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    thing.displayName = trimmed
                    thing.userNamed = true
                    SpotlightIndex.index(thing)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func savePrice() {
        let cleaned = priceDraft.replacingOccurrences(of: ",", with: ".")
        thing.price = Double(cleaned)
        thing.priceSource = ""     // a typed value is the user's own
    }

    private func estimateValue() {
        estimating = true
        aiError = nil
        Task {
            do {
                var details = "Category: \(thing.category)."
                if thing.widthM > 0 {
                    details += " Measured size: \(thing.sizeDescription)."
                }
                if !thing.recognizedText.isEmpty {
                    details += " Text on it: \(thing.recognizedText)."
                }
                let (value, note) = try await ai.estimateValue(
                    image: Store.loadThumb(thing.id),
                    name: thing.displayName, details: details)
                thing.price = value
                thing.priceSource = "ai"
                priceDraft = String(Int(value.rounded()))
                estimateNote = note
            } catch {
                aiError = error.localizedDescription
            }
            estimating = false
        }
    }

    /// Rank OCR lines by how much they look like a serial number:
    /// long, digit-bearing, not a word you'd find in a manual.
    static func serialLike(_ lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.count >= 5 && line.count <= 40
                    && line.contains(where: \.isNumber)
            }
            .sorted { a, b in
                func score(_ s: String) -> Int {
                    var v = 0
                    let upper = s.uppercased()
                    if upper.contains("S/N") || upper.contains("SERIAL")
                        || upper.contains("SN:") { v += 100 }
                    v += s.filter(\.isNumber).count * 2
                    v += s.filter { $0.isUppercase }.count
                    if s.contains(" ") { v -= 5 }
                    return v
                }
                return score(a) > score(b)
            }
            .prefix(5)
            .map { line in
                // strip the "S/N:" prefix if the plate includes it
                var s = line
                for prefix in ["S/N:", "S/N", "SN:", "Serial No.",
                               "Serial:", "Serial"] {
                    if s.uppercased().hasPrefix(prefix.uppercased()) {
                        s = String(s.dropFirst(prefix.count))
                            .trimmingCharacters(
                                in: CharacterSet(charactersIn: " :.#"))
                        break
                    }
                }
                return s.isEmpty ? line : s
            }
    }
}
