// Every occasional-use tool in one place, so the main tabs stay about
// the two things people actually do daily: finding stuff and scanning.
import SwiftData
import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var engine: NavEngine
    @Query(sort: \Room.lastScannedAt, order: .reverse)
    private var rooms: [Room]
    @State private var toolPick: QuickTool?
    @State private var showSettings = false

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
            .sheet(item: $toolPick) { tool in
                RoomToolSheet(tool: tool, rooms: rooms)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
