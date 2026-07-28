// The hub. One field answers the app's defining question — "where is
// my X?" — and a grid of verbs covers everything else without hunting
// through tabs. Deliberately no nagging: no freshness warnings, no
// badges. You come to it; it doesn't come after you.
import NavCore
import SwiftData
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Query(sort: \Thing.lastSeenAt, order: .reverse)
    private var things: [Thing]
    @Query(sort: \Room.lastScannedAt, order: .reverse)
    private var rooms: [Room]
    @Query private var spots: [StorageSpot]
    @Binding var activeRoom: Room?
    @Binding var selectedTab: Int
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var toolPick: QuickTool?
    @State private var pushed: HomeDestination?

    enum HomeDestination: String, Identifiable {
        case storage, insurance, condition, memorylane
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    searchBar
                    if !query.isEmpty {
                        searchResults
                    } else {
                        quickActions
                        if !things.isEmpty { recentStrip }
                        statsFooter
                    }
                }
                .padding()
            }
            .brandBackground()
            .navigationTitle("Theseus")
            .sheet(item: $toolPick) { tool in
                RoomToolSheet(tool: tool, rooms: rooms)
            }
            .sheet(item: $pushed) { destination in
                NavigationStack {
                    Group {
                        switch destination {
                        case .storage: StorageView()
                        case .insurance: InsuranceView()
                        case .condition: ConditionView()
                        case .memorylane: MemoryLaneView()
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { pushed = nil }
                        }
                    }
                }
            }
        }
    }

    // ---- search ----------------------------------------------------------

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Where is my…", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var matches: [Thing] {
        things
            .compactMap { thing -> (Thing, Double)? in
                SmartSearch.score(query: query, thing: thing)
                    .map { (thing, $0) }
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.lastSeenAt > b.0.lastSeenAt
            }
            .prefix(12)
            .map(\.0)
    }

    private var spotMatches: [StorageSpot] {
        let q = query.lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return spots.filter { $0.name.lowercased().contains(q) }
    }

    private var searchResults: some View {
        VStack(spacing: 10) {
            if matches.isEmpty && spotMatches.isEmpty {
                ContentUnavailableView(
                    "No matches", systemImage: "magnifyingglass",
                    description: Text("Nothing you've saved matches "
                                      + "\"\(query)\"."))
            }
            ForEach(spotMatches) { spot in
                Button {
                    pushed = .storage
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: spot.kindSymbol)
                            .font(.title3)
                            .foregroundStyle(Color.brandThread)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial,
                                        in: RoundedRectangle(
                                            cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.name).font(.headline)
                            let count = things.filter {
                                $0.storageID == spot.id
                            }.count
                            Text(count == 1
                                 ? "storage · 1 item"
                                 : "storage · \(count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(matches) { thing in
                Button {
                    locate(thing)
                } label: {
                    HStack(spacing: 12) {
                        ThingRow(thing: thing, showRoom: true,
                                 spotName: thing.storageID.flatMap {
                                     id in spots.first {
                                         $0.id == id
                                     }?.name
                                 })
                        Spacer()
                        Label("Find", systemImage: "location.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.green.opacity(0.2),
                                        in: Capsule())
                            .foregroundStyle(.green)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Search → camera with the item's beacon lit. The whole product
    /// in one tap.
    private func locate(_ thing: Thing) {
        guard let room = thing.room else { return }
        activeRoom = room
        engine.makeActive(room)
        engine.locateTarget = LocateTarget(
            thingID: thing.id, name: thing.displayName,
            x: thing.positionX, y: thing.positionY)
        selectedTab = 1
    }

    // ---- quick actions ---------------------------------------------------

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()),
                            GridItem(.flexible())],
                  spacing: 12) {
            actionCard("camera.viewfinder", "Scan a room",
                       "Map it and save what's inside") {
                if rooms.isEmpty {
                    selectedTab = 3     // create one first
                } else {
                    if activeRoom == nil { activeRoom = rooms.first }
                    selectedTab = 1
                }
            }
            actionCard("location.magnifyingglass", "Find something",
                       "Search everything you own") {
                searchFocused = true
            }
            actionCard("shippingbox", "Storage",
                       "Boxes, closets, drawers — itemized") {
                pushed = .storage
            }
            actionCard("checkmark.shield", "Insurance",
                       "Values, serials, the claim PDF") {
                pushed = .insurance
            }
            actionCard("camera.on.rectangle", "Deposit proof",
                       "Sealed move-in/out evidence") {
                pushed = .condition
            }
            actionCard("clock", "Memory lane",
                       "Your home's diary, by month") {
                pushed = .memorylane
            }
            actionCard("doc.richtext", "Room report",
                       "PDF with photos, sizes, values") {
                toolPick = .report
            }
            actionCard("map", "Floor plan",
                       "Share the map as an image") {
                toolPick = .floorplan
            }
            actionCard("clock.arrow.circlepath", "What changed",
                       "Diff a room against past scans") {
                toolPick = .changes
            }
            actionCard("square.and.arrow.up", "Export data",
                       "Whole inventory as JSON") {
                toolPick = .export
            }
        }
    }

    private func actionCard(_ icon: String, _ title: String,
                            _ subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.brandThread)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial,
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // ---- recents + stats -------------------------------------------------

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently saved")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(things.prefix(10)) { thing in
                        Button {
                            locate(thing)
                        } label: {
                            VStack(spacing: 4) {
                                ThingThumbnail(thingID: thing.id)
                                    .frame(width: 64, height: 64)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 10))
                                Text(thing.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statsFooter: some View {
        let total = things.compactMap(\.price).reduce(0, +)
        return HStack(spacing: 0) {
            stat("\(things.count)", "things")
            Divider().frame(height: 30)
            stat("\(rooms.count)", "rooms")
            Divider().frame(height: 30)
            stat(total > 0
                 ? total.formatted(.currency(
                    code: Locale.current.currency?.identifier ?? "USD")
                    .precision(.fractionLength(0)))
                 : "—",
                 "logged value")
        }
        .padding(.vertical, 8)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// ---- tools plumbing ------------------------------------------------------

enum QuickTool: String, Identifiable, CaseIterable {
    case report, measure, fit, floorplan, changes, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .report: return "Room report"
        case .measure: return "Measure"
        case .fit: return "Will it fit?"
        case .floorplan: return "Share floor plan"
        case .changes: return "What changed"
        case .export: return "Export inventory"
        }
    }
}

/// One sheet serves every room-scoped tool: pick the room, get the
/// tool. Tools that produce a file jump straight to the share sheet.
struct RoomToolSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: QuickTool
    let rooms: [Room]
    @Query private var allThings: [Thing]
    @Query private var allSpots: [StorageSpot]
    @State private var shareURL: URL?
    @State private var exportFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if tool == .export {
                    exportNow
                } else if rooms.isEmpty {
                    ContentUnavailableView(
                        "No rooms yet", systemImage: "square.grid.2x2",
                        description: Text("Scan a room first."))
                } else {
                    roomList
                }
            }
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $shareURL) { url in
                ShareURLSheet(url: url)
            }
            .alert("Nothing to export yet", isPresented: $exportFailed) {
                Button("OK") { dismiss() }
            }
        }
    }

    private var roomList: some View {
        List(rooms) { room in
            switch tool {
            case .measure:
                NavigationLink(room.name) { MeasureView(room: room) }
            case .fit:
                NavigationLink(room.name) { FitThroughView(room: room) }
            case .changes:
                NavigationLink(room.name) { ChangesView(room: room) }
            case .report, .floorplan:
                Button {
                    shareURL = tool == .report
                        ? Reports.roomReportPDF(room: room)
                        : Reports.floorPlanPNG(room: room)
                    if shareURL == nil { exportFailed = true }
                } label: {
                    HStack {
                        Text(room.name)
                        Spacer()
                        Text("\(room.things.count) things")
                            .foregroundStyle(.secondary)
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.brandThread)
                    }
                }
            case .export:
                EmptyView()
            }
        }
    }

    private var exportNow: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(Color.brandThread)
            Text("Everything you've saved, one JSON file — names, "
                 + "rooms, positions, sizes, values, dates.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Export") {
                shareURL = Reports.inventoryJSON(
                    rooms: rooms, allThings: allThings,
                    spots: allSpots)
                if shareURL == nil { exportFailed = true }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct ShareURLSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) {}
}
