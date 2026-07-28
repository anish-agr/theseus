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
                                        .foregroundStyle(.cyan)
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
            Section("Things") {
                let moved = room.things.filter { thing in
                    thing.sightings.contains { $0.movedSincePrevious }
                }
                let missing = room.things.filter(\.isMissing)
                LabeledContent("Moved recently", value: "\(moved.count)")
                LabeledContent("Missing", value: "\(missing.count)")
                ForEach(moved.prefix(10)) { thing in
                    ThingRow(thing: thing, showRoom: false)
                }
            }
            if let error {
                Text(error).foregroundStyle(.orange)
            }
        }
        .navigationTitle("What changed")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "grid-", with: "")
        return String(name.prefix(16)).replacingOccurrences(of: "T",
                                                            with: " ")
    }

    private func compute(_ url: URL) {
        guard let old = Store.loadGrid(url: url) else {
            error = "That snapshot could not be read"
            return
        }
        guard old.width == engine.grid.width,
              old.height == engine.grid.height else {
            error = "That scan used a different map size"
            return
        }
        error = nil
        report = diffReport(old, engine.grid)
    }
}
