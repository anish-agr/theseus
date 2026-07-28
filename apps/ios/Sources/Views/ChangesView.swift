// "What changed since yesterday" — compares the live map against an
// archived scan of the same room, and the things list against its own
// sighting history.
import NavCore
import SwiftUI

struct ChangesView: View {
    @EnvironmentObject var engine: NavEngine
    let room: Room
    @State private var selected: URL?
    @State private var report: DiffReport?
    @State private var error: String?

    private var history: [URL] { Store.gridHistory(room.id) }

    var body: some View {
        List {
            if history.isEmpty {
                ContentUnavailableView(
                    "No earlier scan yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Scan this room again later and "
                                      + "Theseus will show what moved."))
            } else {
                Section("Compare against") {
                    ForEach(history, id: \.self) { url in
                        Button {
                            selected = url
                            compute(url)
                        } label: {
                            HStack {
                                Text(label(for: url))
                                Spacer()
                                if selected == url {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.brandThread)
                                }
                            }
                        }
                    }
                }
            }
            if let report {
                Section("Floor") {
                    LabeledContent("Newly blocked",
                                   value: "\(report.appeared) cells")
                    LabeledContent("Newly clear",
                                   value: "\(report.vanished) cells")
                    ForEach(report.byLabel.sorted(by: { $0.key < $1.key }),
                            id: \.key) { key, count in
                        LabeledContent(key, value: "\(count)")
                    }
                }
            }
            // the git-diff of your stuff: + added, - missing, ~ moved
            let since = selected.flatMap(archiveDate)
                ?? Date().addingTimeInterval(-604800)
            let added = room.things.filter {
                $0.firstSeenAt > since && !$0.isMissing
            }
            let missing = room.things.filter(\.isMissing)
            let moved = room.things.filter { thing in
                !missing.contains { $0.id == thing.id }
                    && !added.contains { $0.id == thing.id }
                    && thing.sightings.contains {
                        $0.movedSincePrevious && $0.at > since
                    }
            }
            if !added.isEmpty {
                Section("+ Added — \(added.count)") {
                    ForEach(added) { thing in
                        diffRow(thing, symbol: "plus.circle.fill",
                                color: .green)
                    }
                }
            }
            if !missing.isEmpty {
                Section("− Missing — \(missing.count)") {
                    ForEach(missing) { thing in
                        diffRow(thing, symbol: "minus.circle.fill",
                                color: .red)
                    }
                }
            }
            if !moved.isEmpty {
                Section("~ Moved — \(moved.count)") {
                    ForEach(moved) { thing in
                        diffRow(thing,
                                symbol: "arrow.triangle.swap",
                                color: .orange)
                    }
                }
            }
            if added.isEmpty, missing.isEmpty, moved.isEmpty {
                Section("Things") {
                    Text("No object changes "
                         + (selected == nil
                            ? "in the last week."
                            : "since that scan."))
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(.orange)
            }
        }
        .navigationTitle("What changed")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diffRow(_ thing: Thing, symbol: String,
                         color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            ThingThumbnail(thingID: thing.id)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(thing.displayName).font(.callout)
                Text("last seen "
                     + thing.lastSeenAt.formatted(
                        date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "grid-", with: "")
        return String(name.prefix(16)).replacingOccurrences(of: "T",
                                                            with: " ")
    }

    /// Archive filenames carry their timestamp with ":" flattened to
    /// "-" (grid-2026-07-28T07-37-08Z.bin); reverse it to get a Date.
    private func archiveDate(_ url: URL) -> Date? {
        let raw = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "grid-", with: "")
        guard let tIndex = raw.firstIndex(of: "T") else { return nil }
        let day = raw[..<tIndex]
        let time = raw[raw.index(after: tIndex)...]
            .replacingOccurrences(of: "-", with: ":")
        return ISO8601DateFormatter().date(from: "\(day)T\(time)")
    }

    private func compute(_ url: URL) {
        guard let old = Store.loadGrid(url: url) else {
            error = "That snapshot could not be read"
            return
        }
        // compare against THIS room's current map — the engine's live
        // grid may belong to a different room right now
        let current: OccupancyGrid?
        if engine.currentRoomID == room.id {
            current = engine.grid
        } else {
            current = Store.loadGrid(room.id)
        }
        guard let current else {
            error = "No current scan for this room yet"
            return
        }
        guard old.width == current.width,
              old.height == current.height else {
            error = "That scan used a different map size"
            return
        }
        error = nil
        report = diffReport(old, current)
    }
}
