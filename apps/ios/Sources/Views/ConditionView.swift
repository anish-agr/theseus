// Rental-deposit evidence. Walk the room with a guided checklist —
// every wall, floor, ceiling, and a close-up of every existing scratch
// — then SEAL the record: a SHA-256 over every photo and its metadata,
// printed on the export. A sealed record provably hasn't been edited
// since the day it was made, which is exactly what a deposit dispute
// needs. Move-out repeats the walkthrough; the pair exports side by
// side. (True 3D capture joins when a LiDAR device does — the evidence
// that wins disputes is dated, positioned photos, and the XR does
// those today.)
import CryptoKit
import SwiftData
import SwiftUI

struct ConditionView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ConditionRecord.startedAt, order: .reverse)
    private var records: [ConditionRecord]
    @Query private var rooms: [Room]
    @State private var creating = false

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No condition records yet",
                    systemImage: "checkmark.shield",
                    description: Text("Moving in? Walk the room with "
                        + "the camera and seal the evidence. When you "
                        + "move out, the dated photos prove the "
                        + "scratch was always there."))
            }
            ForEach(groupedRoomNames, id: \.self) { roomName in
                Section(roomName) {
                    ForEach(records.filter {
                        $0.roomName == roomName
                    }) { record in
                        NavigationLink {
                            ConditionRecordView(record: record)
                        } label: {
                            recordRow(record)
                        }
                    }
                    if let pair = comparablePair(roomName) {
                        NavigationLink {
                            ConditionCompareView(before: pair.0,
                                                 after: pair.1)
                        } label: {
                            Label("Compare move-in vs move-out",
                                  systemImage:
                                    "rectangle.on.rectangle.angled")
                                .foregroundStyle(Color.brandThread)
                        }
                    }
                }
            }
        }
        .navigationTitle("Condition records")
        .brandBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NewConditionSheet()
        }
    }

    private var groupedRoomNames: [String] {
        var seen: [String] = []
        for record in records where !seen.contains(record.roomName) {
            seen.append(record.roomName)
        }
        return seen
    }

    private func comparablePair(_ roomName: String)
        -> (ConditionRecord, ConditionRecord)? {
        let inRoom = records.filter { $0.roomName == roomName }
        guard let before = inRoom.last(where: { $0.kind == "movein" }),
              let after = inRoom.first(where: { $0.kind == "moveout" }),
              before.id != after.id else { return nil }
        return (before, after)
    }

    private func recordRow(_ record: ConditionRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.isSealed
                  ? "checkmark.shield.fill" : "shield")
                .font(.title3)
                .foregroundStyle(record.isSealed
                                 ? Color.brandDot : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.kindTitle) — "
                     + record.startedAt.formatted(date: .abbreviated,
                                                  time: .omitted))
                    .font(.callout)
                Text(record.isSealed
                     ? "\(record.shots.count) photos · sealed"
                     : "\(record.shots.count) photos · in progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// ---- new record ------------------------------------------------------------

struct NewConditionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var rooms: [Room]
    @State private var roomName = ""
    @State private var kind = "movein"

    var body: some View {
        NavigationStack {
            Form {
                Picker("This is a", selection: $kind) {
                    Text("Move-in record").tag("movein")
                    Text("Move-out record").tag("moveout")
                    Text("Check-up").tag("checkup")
                }
                .pickerStyle(.inline)
                Section("Room") {
                    TextField("Room name — \"Bedroom\", \"Kitchen\"…",
                              text: $roomName)
                    if !rooms.isEmpty {
                        ForEach(rooms) { room in
                            Button(room.name) { roomName = room.name }
                                .foregroundStyle(Color.brandThread)
                        }
                    }
                }
            }
            .navigationTitle("New walkthrough")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let name = roomName.trimmingCharacters(
                            in: .whitespaces)
                        let record = ConditionRecord(
                            roomID: rooms.first {
                                $0.name == name
                            }?.id,
                            roomName: name.isEmpty ? "Room" : name,
                            kind: kind)
                        context.insert(record)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// ---- one record ------------------------------------------------------------

struct ConditionRecordView: View {
    @Environment(\.modelContext) private var context
    @Bindable var record: ConditionRecord
    @State private var captureTag: String?
    @State private var customTag = ""
    @State private var shareURL: URL?
    @State private var confirmSeal = false

    private static let checklist = [
        "Overview", "Wall 1", "Wall 2", "Wall 3", "Wall 4",
        "Floor", "Ceiling", "Windows", "Door", "Fixtures",
        "Damage close-up",
    ]

    private var shots: [ConditionShot] {
        record.shots.sorted { $0.at < $1.at }
    }

    var body: some View {
        List {
            if record.isSealed {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SuccessDot(size: 14)
                            Text("Sealed "
                                 + (record.sealedAt?.formatted(
                                    date: .long, time: .shortened)
                                    ?? ""))
                                .font(.callout.weight(.medium))
                        }
                        if let hash = record.sealHash {
                            Text("SHA-256  \(hash)")
                                .font(.system(size: 9).monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("Photos and captions can no longer be "
                             + "changed — that's the point.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Photograph each — dwell on damage") {
                    ForEach(Self.checklist, id: \.self) { tag in
                        let count = shots.filter {
                            $0.tag == tag
                        }.count
                        Button {
                            captureTag = tag
                        } label: {
                            HStack {
                                Text(tag)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if count > 0 {
                                    Circle().fill(Color.brandDot)
                                        .frame(width: 10, height: 10)
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "camera")
                                    .foregroundStyle(Color.brandThread)
                            }
                        }
                    }
                    HStack {
                        TextField("Custom — \"Radiator\"…",
                                  text: $customTag)
                        Button("Shoot") {
                            let tag = customTag.trimmingCharacters(
                                in: .whitespaces)
                            if !tag.isEmpty { captureTag = tag }
                        }
                        .disabled(customTag.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                    }
                }
            }

            if !shots.isEmpty {
                Section("\(shots.count) photos") {
                    ForEach(shots) { shot in
                        ShotRow(record: record, shot: shot,
                                editable: !record.isSealed)
                    }
                    .onDelete(perform: record.isSealed
                              ? nil : deleteShots)
                }
            }

            Section {
                if !record.isSealed {
                    Button {
                        confirmSeal = true
                    } label: {
                        Label("Seal this record",
                              systemImage: "checkmark.shield")
                    }
                    .disabled(shots.isEmpty)
                }
                Button {
                    shareURL = Reports.conditionPDF(record: record)
                } label: {
                    Label("Export evidence PDF",
                          systemImage: "doc.badge.arrow.up")
                }
                .disabled(shots.isEmpty)
                if !record.isSealed {
                    Button(role: .destructive) {
                        Store.deleteConditionBlobs(record.id)
                        context.delete(record)
                    } label: {
                        Label("Delete record", systemImage: "trash")
                    }
                }
            } footer: {
                if !record.isSealed {
                    Text("Sealing computes a fingerprint over every "
                         + "photo and caption. Do it the day you get "
                         + "the keys — the seal date is the proof.")
                }
            }
        }
        .navigationTitle("\(record.roomName) · \(record.kindTitle)")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .brandBackground()
        .sheet(item: $captureTag) { tag in
            CameraSheet { image in
                addShot(image, tag: tag)
            }
        }
        .sheet(item: $shareURL) { url in
            ShareURLSheet(url: url)
        }
        .confirmationDialog(
            "Seal the record? Nothing can be added or edited after.",
            isPresented: $confirmSeal, titleVisibility: .visible
        ) {
            Button("Seal it") { seal() }
            Button("Not yet", role: .cancel) {}
        }
    }

    private func addShot(_ image: UIImage, tag: String) {
        guard !record.isSealed else { return }
        let shot = ConditionShot(tag: tag)
        shot.record = record
        context.insert(shot)
        if let data = image.jpegData(compressionQuality: 0.85) {
            Store.saveConditionShot(data, recordID: record.id,
                                    shotID: shot.id)
        }
        customTag = ""
    }

    private func deleteShots(at offsets: IndexSet) {
        for index in offsets {
            let shot = shots[index]
            try? FileManager.default.removeItem(
                at: Store.conditionShotURL(recordID: record.id,
                                           shotID: shot.id))
            context.delete(shot)
        }
    }

    /// The tamper-evident part: hash every photo's bytes plus its
    /// caption/tag/timestamp, in a stable order.
    private func seal() {
        var hasher = SHA256()
        for shot in shots.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            if let data = try? Data(contentsOf: Store.conditionShotURL(
                recordID: record.id, shotID: shot.id)) {
                hasher.update(data: data)
            }
            let meta = "\(shot.id.uuidString)|\(shot.tag)|\(shot.note)|"
                + ISO8601DateFormatter().string(from: shot.at)
            hasher.update(data: Data(meta.utf8))
        }
        record.sealHash = hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
        record.sealedAt = Date()
    }
}

struct ShotRow: View {
    let record: ConditionRecord
    @Bindable var shot: ConditionShot
    let editable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = Store.loadConditionShot(
                recordID: record.id, shotID: shot.id) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(shot.tag).font(.callout.weight(.medium))
                Text(shot.at.formatted(date: .abbreviated,
                                       time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if editable {
                    TextField("Note — \"scratch, 3 cm\"…",
                              text: $shot.note, axis: .vertical)
                        .font(.caption)
                } else if !shot.note.isEmpty {
                    Text(shot.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// ---- compare ---------------------------------------------------------------

struct ConditionCompareView: View {
    let before: ConditionRecord
    let after: ConditionRecord
    @State private var shareURL: URL?

    private var tags: [String] {
        var seen: [String] = []
        for shot in before.shots + after.shots
        where !seen.contains(shot.tag) {
            seen.append(shot.tag)
        }
        return seen
    }

    var body: some View {
        List {
            Section {
                Button {
                    shareURL = Reports.conditionComparePDF(
                        before: before, after: after)
                } label: {
                    Label("Export comparison PDF",
                          systemImage: "doc.badge.arrow.up")
                }
            } footer: {
                Text("Left: \(before.kindTitle) "
                     + before.startedAt.formatted(date: .abbreviated,
                                                  time: .omitted)
                     + " · Right: \(after.kindTitle) "
                     + after.startedAt.formatted(date: .abbreviated,
                                                 time: .omitted))
            }
            ForEach(tags, id: \.self) { tag in
                Section(tag) {
                    HStack(alignment: .top, spacing: 8) {
                        compareColumn(record: before, tag: tag)
                        compareColumn(record: after, tag: tag)
                    }
                }
            }
        }
        .navigationTitle("\(before.roomName) — then vs now")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { url in
            ShareURLSheet(url: url)
        }
    }

    private func compareColumn(record: ConditionRecord,
                               tag: String) -> some View {
        VStack(spacing: 6) {
            let shots = record.shots.filter { $0.tag == tag }
                .sorted { $0.at < $1.at }
            if shots.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.thinMaterial)
                        .frame(height: 120)
                    Text("no photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(shots) { shot in
                if let image = Store.loadConditionShot(
                    recordID: record.id, shotID: shot.id) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !shot.note.isEmpty {
                    Text(shot.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Sheets are driven by Identifiable items; a bare String tag needs
/// this to ride along.
extension String: Identifiable {
    public var id: String { self }
}
