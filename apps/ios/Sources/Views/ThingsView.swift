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
    @Binding var activeRoom: Room?
    @Binding var selectedTab: Int
    @State private var query = ""
    @State private var filter: Filter = .all

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
                        ThingRow(thing: thing, showRoom: true)
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

    var body: some View {
        HStack(spacing: 12) {
            ThingThumbnail(thingID: thing.id)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(thing.displayName).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    if showRoom, let room = thing.room {
                        Text(room.name)
                        Text("·")
                    }
                    Text(thing.sizeDescription)
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
    @State private var renaming = false
    @State private var draft = ""
    @State private var priceDraft = ""
    @State private var receiptPick: PhotosPickerItem?
    @State private var hasReceipt = false

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
            Section {
                Button {
                    // camera + green beacon + live distance — the
                    // default "find" (turn-by-turn stays one tap away
                    // on the locate bar)
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
    }
}
