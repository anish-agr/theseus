// The inventory: everything the app has ever seen, across every room.
// Search matches your own names first, then the classifier's label,
// then any text read off the object — so "NESCAFÉ" finds the jar.
import NavCore
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
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Things")
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
        let q = query.lowercased()
        return base
            .filter { $0.searchHaystack.contains(q) }
            .sorted { a, b in
                // exact-ish name matches rank above text-on-object hits
                let aName = a.displayName.lowercased().contains(q)
                let bName = b.displayName.lowercased().contains(q)
                if aName != bName { return aName }
                return a.lastSeenAt > b.lastSeenAt
            }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let thing = matches[index]
            Store.deleteThingBlobs(thing.id)
            context.delete(thing)
        }
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
            Section {
                Button {
                    guard let room = thing.room else { return }
                    activeRoom = room
                    engine.startGuidance(
                        to: Vec(thing.positionX, thing.positionY),
                        name: thing.displayName)
                    selectedTab = 1
                    dismiss()
                } label: {
                    Label("Take me there", systemImage: "figure.walk")
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
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Save") {
                let trimmed = draft.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    thing.displayName = trimmed
                    thing.userNamed = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
