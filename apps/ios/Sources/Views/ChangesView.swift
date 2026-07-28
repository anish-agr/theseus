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
            if !added.isEmpty || !missing.isEmpty || !moved.isEmpty {
                Section("On the map") {
                    ChangeMapView(room: room, since: since,
                                  added: added, missing: missing,
                                  moved: moved)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                    HStack(spacing: 14) {
                        legend(.green, "added")
                        legend(.red, "missing")
                        legend(.orange, "moved →")
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
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

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
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
}

/// The "google maps" half of what-changed: the floor plan with the
/// diff drawn ON it — green dots where things appeared, red rings
/// where they went missing, orange arrows from where something WAS to
/// where it is now.
struct ChangeMapView: View {
    let room: Room
    let since: Date
    let added: [Thing]
    let missing: [Thing]
    let moved: [Thing]
    @State private var plan: UIImage?
    @State private var grid: OccupancyGrid?

    var body: some View {
        Group {
            if let plan, let grid {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: plan)
                            .resizable()
                            .frame(width: side, height: side)
                        Canvas { ctx, _ in
                            drawDiff(ctx: ctx, side: side, grid: grid)
                        }
                        .frame(width: side, height: side)
                    }
                    .frame(maxWidth: .infinity)
                }
                .aspectRatio(1, contentMode: .fit)
            } else {
                Text("No saved map for this room yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .onAppear {
            grid = Store.loadGrid(room.id)
            plan = Reports.floorPlanImage(room: room)
        }
    }

    private func toPx(_ wx: Double, _ wy: Double, side: CGFloat,
                      grid: OccupancyGrid) -> CGPoint {
        // same mapping as Reports.drawFloorPlan: world → square plan,
        // +y up flipped to screen-down
        let scale = side / CGFloat(Double(grid.width) * grid.cellSize)
        return CGPoint(
            x: CGFloat(wx - grid.origin.x) * scale,
            y: side - CGFloat(wy - grid.origin.y) * scale)
    }

    private func drawDiff(ctx: GraphicsContext, side: CGFloat,
                          grid: OccupancyGrid) {
        for thing in added where thing.hasPosition {
            let p = toPx(thing.positionX, thing.positionY,
                         side: side, grid: grid)
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4,
                                       width: 8, height: 8)),
                with: .color(.green))
        }
        for thing in missing where thing.hasPosition {
            let p = toPx(thing.positionX, thing.positionY,
                         side: side, grid: grid)
            ctx.stroke(
                Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5,
                                       width: 10, height: 10)),
                with: .color(.red), lineWidth: 2)
        }
        for thing in moved where thing.hasPosition {
            // where it was: the last position recorded BEFORE the
            // comparison point (fall back to its earliest sighting)
            let ordered = thing.sightings.sorted { $0.at < $1.at }
            let before = ordered.last { $0.at <= since } ?? ordered.first
            guard let before else { continue }
            let from = toPx(before.positionX, before.positionY,
                            side: side, grid: grid)
            let to = toPx(thing.positionX, thing.positionY,
                          side: side, grid: grid)
            guard hypot(to.x - from.x, to.y - from.y) > 4 else {
                continue
            }
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            ctx.stroke(line, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 2,
                                          lineCap: .round,
                                          dash: [4, 3]))
            // arrowhead at the new spot
            let angle = atan2(to.y - from.y, to.x - from.x)
            var head = Path()
            head.move(to: to)
            head.addLine(to: CGPoint(
                x: to.x - 8 * cos(angle - 0.45),
                y: to.y - 8 * sin(angle - 0.45)))
            head.move(to: to)
            head.addLine(to: CGPoint(
                x: to.x - 8 * cos(angle + 0.45),
                y: to.y - 8 * sin(angle + 0.45)))
            ctx.stroke(head, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 2,
                                          lineCap: .round))
        }
    }

}
