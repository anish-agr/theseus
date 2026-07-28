// Every occasional-use tool in one place, so the main tabs stay about
// the two things people actually do daily: finding stuff and scanning.
import SwiftData
import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var engine: NavEngine
    @Query(sort: \Room.lastScannedAt, order: .reverse)
    private var rooms: [Room]
    @Query private var allThings: [Thing]
    @Query private var allSpots: [StorageSpot]
    @Query private var allRecords: [ConditionRecord]
    @State private var toolPick: QuickTool?
    @State private var showSettings = false
    @State private var shareURL: URL?
    @State private var building = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your home's memory") {
                    navRow("Storage", icon: "shippingbox",
                           subtitle: "Boxes, closets, drawers — what "
                           + "lives inside what") {
                        StorageView()
                    }
                    navRow("Insurance", icon: "checkmark.shield",
                           subtitle: "Values, serials, warranties, "
                           + "and the claim-ready PDF") {
                        InsuranceView()
                    }
                    navRow("Deposit proof",
                           icon: "camera.on.rectangle",
                           subtitle: "Sealed move-in/move-out "
                           + "condition records") {
                        ConditionView()
                    }
                    navRow("Memory lane", icon: "clock",
                           subtitle: "Everything saved, scanned and "
                           + "sealed — by month") {
                        MemoryLaneView()
                    }
                }
                Section("Space") {
                    toolRow(.measure, icon: "ruler",
                            subtitle: "Straight-line and walking "
                            + "distances, narrowest gap on the way")
                    toolRow(.fit, icon: "arrow.left.and.right.square",
                            subtitle: "Will the couch make it? Answers "
                            + "with the pinch point located")
                    toolRow(.changes, icon: "clock.arrow.circlepath",
                            subtitle: "Diff a room against its last "
                            + "scans: blocked, cleared, moved")
                }
                Section("Share") {
                    toolRow(.report, icon: "doc.richtext",
                            subtitle: "Insurance/moving PDF: photos, "
                            + "sizes, values, floor plan")
                    toolRow(.floorplan, icon: "map",
                            subtitle: "The room map as an image")
                    toolRow(.export, icon: "square.and.arrow.up",
                            subtitle: "Whole inventory as JSON")
                    shareRow("Back up everything",
                             icon: "externaldrive.badge.icloud",
                             subtitle: "One .zip — every photo, map "
                             + "and record. Keep it off this phone.") {
                        Backup.fullBackup(rooms: rooms,
                                          things: allThings,
                                          spots: allSpots,
                                          records: allRecords)
                    }
                    shareRow("Household snapshot",
                             icon: "person.2",
                             subtitle: "Read-only bundle for a "
                             + "partner or landlord — PDFs, plans, "
                             + "inventory") {
                        Backup.householdShare(rooms: rooms,
                                              things: allThings,
                                              spots: allSpots)
                    }
                    shareRow("Move manifest",
                             icon: "shippingbox.and.arrow.backward",
                             subtitle: "A tickable checklist per box "
                             + "— nothing vanishes in the truck") {
                        Reports.moveManifestPDF(spots: allSpots,
                                                things: allThings)
                    }
                }
                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label {
                            Text("Settings & data")
                        } icon: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(Color.brandThread)
                        }
                    }
                }
            }
            .navigationTitle("Tools")
            .brandBackground()
            .sheet(item: $toolPick) { tool in
                RoomToolSheet(tool: tool, rooms: rooms)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $shareURL) { url in
                ShareURLSheet(url: url)
            }
        }
    }

    /// A share-producing row: builds the file off the main thread's
    /// hot path, thread-loading while it works, then the share sheet.
    private func shareRow(_ title: String, icon: String,
                          subtitle: String,
                          build: @escaping () -> URL?) -> some View {
        Button {
            guard !building else { return }
            building = true
            Task {
                shareURL = build()
                building = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.brandThread)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if building { ThreadLoadingView(size: 22) }
            }
        }
    }

    private func navRow<Destination: View>(
        _ title: String, icon: String, subtitle: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.brandThread)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toolRow(_ tool: QuickTool, icon: String,
                         subtitle: String) -> some View {
        Button {
            toolPick = tool
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.brandThread)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
