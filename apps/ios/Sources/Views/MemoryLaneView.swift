// Memory lane — the home's diary, assembled from data the app already
// keeps: first captures, moves, scans, sealed condition records. Not a
// habit tracker, no streaks, no guilt (Anish's law: nobody scans their
// home daily); just "look at everything from July" whenever you feel
// like looking. The photos do the remembering.
import SwiftData
import SwiftUI

struct MemoryLaneView: View {
    @Query private var things: [Thing]
    @Query private var sessions: [ScanSession]
    @Query private var records: [ConditionRecord]
    @Query private var rooms: [Room]

    struct LaneEvent: Identifiable {
        let id: String
        let date: Date
        let icon: String
        let title: String
        let subtitle: String
        let thingID: UUID?
    }

    private var events: [LaneEvent] {
        var out: [LaneEvent] = []
        for thing in things {
            out.append(LaneEvent(
                id: "new-\(thing.id)", date: thing.firstSeenAt,
                icon: "sparkle",
                title: thing.displayName,
                subtitle: thing.room.map { "saved in the \($0.name)" }
                    ?? "saved",
                thingID: thing.id))
            for s in thing.sightings where s.movedSincePrevious {
                out.append(LaneEvent(
                    id: "move-\(s.id)", date: s.at,
                    icon: "arrow.triangle.swap",
                    title: thing.displayName,
                    subtitle: "moved to a new spot",
                    thingID: thing.id))
            }
        }
        for session in sessions {
            guard let ended = session.endedAt else { continue }
            let name = session.room?.name ?? "a room"
            var line = "scanned \(name)"
            if session.thingsAdded > 0 {
                line += " · \(session.thingsAdded) new things"
            }
            out.append(LaneEvent(
                id: "scan-\(session.id)", date: ended,
                icon: "camera.viewfinder",
                title: "Room scan", subtitle: line, thingID: nil))
        }
        for record in records {
            guard let sealed = record.sealedAt else { continue }
            out.append(LaneEvent(
                id: "seal-\(record.id)", date: sealed,
                icon: "checkmark.shield",
                title: "\(record.roomName) \(record.kindTitle)",
                subtitle: "condition record sealed — "
                    + "\(record.shots.count) photos",
                thingID: nil))
        }
        return out.sorted { $0.date > $1.date }
    }

    private var months: [(String, [LaneEvent])] {
        var order: [String] = []
        var buckets: [String: [LaneEvent]] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        for event in events.prefix(400) {
            let key = formatter.string(from: event.date)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(event)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        List {
            if events.isEmpty {
                ContentUnavailableView(
                    "Nothing remembered yet",
                    systemImage: "clock",
                    description: Text("Scan a room and save a few "
                        + "things — this becomes the story of your "
                        + "home."))
            }
            ForEach(months, id: \.0) { month, monthEvents in
                Section(month) {
                    ForEach(monthEvents) { event in
                        HStack(spacing: 12) {
                            if let thingID = event.thingID {
                                ThingThumbnail(thingID: thingID)
                                    .frame(width: 44, height: 44)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 8))
                            } else {
                                Image(systemName: event.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color.brandThread)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        .thinMaterial,
                                        in: RoundedRectangle(
                                            cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.callout)
                                Text(event.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.date, format: .dateTime.day())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Memory lane")
    }
}
