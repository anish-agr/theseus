// Off-device backup — the gap that mattered most: an inventory that
// dies with the phone can't prove anything about the fire that took
// the phone. One tap builds a single .zip (photos, receipts, maps,
// condition evidence, plus a database.json describing everything) and
// hands it to the share sheet — AirDrop it, save it to iCloud Drive,
// email it to yourself. Any computer can open it.
//
// The zip writer is deliberately minimal: STORE method only (JPEGs
// and LZFSE'd world maps don't compress again), which keeps it ~90
// lines and byte-for-byte verifiable.
import Foundation
import SwiftData

// ---- store-method zip writer ----------------------------------------------

struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    mutating func add(path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = Self.crc32(data)
        let offset = UInt32(body.count)

        func le16(_ v: UInt16) -> Data {
            withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
        func le32(_ v: UInt32) -> Data {
            withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }

        // local file header
        body.append(le32(0x0403_4B50))
        body.append(le16(20))            // version needed
        body.append(le16(0))             // flags
        body.append(le16(0))             // method: store
        body.append(le16(0))             // mod time
        body.append(le16(0x21))          // mod date (1980-01-01)
        body.append(le32(crc))
        body.append(le32(UInt32(data.count)))
        body.append(le32(UInt32(data.count)))
        body.append(le16(UInt16(name.count)))
        body.append(le16(0))             // extra len
        body.append(name)
        body.append(data)

        // central directory entry
        central.append(le32(0x0201_4B50))
        central.append(le16(20))         // version made by
        central.append(le16(20))         // version needed
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0x21))
        central.append(le32(crc))
        central.append(le32(UInt32(data.count)))
        central.append(le32(UInt32(data.count)))
        central.append(le16(UInt16(name.count)))
        central.append(le16(0))          // extra
        central.append(le16(0))          // comment
        central.append(le16(0))          // disk
        central.append(le16(0))          // internal attrs
        central.append(le32(0))          // external attrs
        central.append(le32(offset))
        central.append(name)
        count += 1
    }

    func finish() -> Data {
        func le16(_ v: UInt16) -> Data {
            withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
        func le32(_ v: UInt32) -> Data {
            withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
        var out = body
        out.append(central)
        out.append(le32(0x0605_4B50))    // end of central directory
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(count))
        out.append(le16(count))
        out.append(le32(UInt32(central.count)))
        out.append(le32(UInt32(body.count)))
        out.append(le16(0))
        return out.count > 22 ? out : out
    }
}

// ---- the archives ----------------------------------------------------------

enum Backup {
    /// Everything: every blob under Store.root plus a full JSON dump
    /// of the database. Keep this file somewhere the fire can't reach.
    static func fullBackup(rooms: [Room], things: [Thing],
                           spots: [StorageSpot],
                           records: [ConditionRecord]) -> URL? {
        var zip = ZipWriter()

        // 1. the database, self-describing
        if let db = databaseJSON(rooms: rooms, things: things,
                                 spots: spots, records: records) {
            zip.add(path: "database.json", data: db)
        }

        // 2. every stored blob, preserving the tree
        let root = Store.root
        if let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in e {
                let isDir = (try? url.resourceValues(
                    forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard !isDir,
                      let data = try? Data(contentsOf: url) else {
                    continue
                }
                let rel = url.path.replacingOccurrences(
                    of: root.path + "/", with: "")
                zip.add(path: "blobs/" + rel, data: data)
            }
        }

        let stamp = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-backup-\(stamp).zip")
        do {
            try zip.finish().write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    /// The read-only snapshot for a partner / landlord / agent: the
    /// human-readable documents only — insurance PDF, per-room report
    /// PDFs, floor plans, inventory JSON. Opens anywhere.
    static func householdShare(rooms: [Room], things: [Thing],
                               spots: [StorageSpot]) -> URL? {
        var zip = ZipWriter()
        if let pdf = Reports.insurancePDF(rooms: rooms, things: things,
                                          spots: spots),
           let data = try? Data(contentsOf: pdf) {
            zip.add(path: "insurance-report.pdf", data: data)
        }
        for room in rooms {
            if let pdf = Reports.roomReportPDF(room: room),
               let data = try? Data(contentsOf: pdf) {
                zip.add(path: "rooms/\(safe(room.name))-report.pdf",
                        data: data)
            }
            if let png = Reports.floorPlanPNG(room: room),
               let data = try? Data(contentsOf: png) {
                zip.add(path: "rooms/\(safe(room.name))-floorplan.png",
                        data: data)
            }
        }
        if let json = Reports.inventoryJSON(rooms: rooms,
                                            allThings: things,
                                            spots: spots),
           let data = try? Data(contentsOf: json) {
            zip.add(path: "inventory.json", data: data)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-home-snapshot.zip")
        do {
            try zip.finish().write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    // ---- database dump ---------------------------------------------------

    private static func databaseJSON(rooms: [Room], things: [Thing],
                                     spots: [StorageSpot],
                                     records: [ConditionRecord])
        -> Data? {
        func iso(_ d: Date?) -> Any { d.map {
            ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

        let roomRows: [[String: Any]] = rooms.map { room in
            ["id": room.id.uuidString, "name": room.name,
             "floor_area_m2": room.floorAreaM2,
             "last_scanned": iso(room.lastScannedAt)]
        }
        let thingRows: [[String: Any]] = things.map { thing in
            var row: [String: Any] = [
                "id": thing.id.uuidString,
                "name": thing.displayName,
                "category": thing.category,
                "room": thing.room?.name ?? NSNull(),
                "first_seen": iso(thing.firstSeenAt),
                "last_seen": iso(thing.lastSeenAt),
                "photo": "blobs/things/\(thing.id.uuidString).jpg",
            ]
            if thing.hasPosition {
                row["position_m"] = [thing.positionX, thing.positionY]
            }
            if let p = thing.price {
                row["value"] = p
                row["value_source"] = thing.priceSource.isEmpty
                    ? "user" : thing.priceSource
            }
            if let d = thing.purchaseDate { row["bought"] = iso(d) }
            if let s = thing.serialNumber { row["serial"] = s }
            if let w = thing.warrantyUntil {
                row["warranty_until"] = iso(w)
            }
            if let s = thing.aiSummary { row["description"] = s }
            if let id = thing.storageID {
                row["storage_id"] = id.uuidString
            }
            return row
        }
        let spotRows: [[String: Any]] = spots.map { spot in
            ["id": spot.id.uuidString, "name": spot.name,
             "kind": spot.kind,
             "parent_id": spot.parentID?.uuidString ?? NSNull()]
        }
        let recordRows: [[String: Any]] = records.map { record in
            ["id": record.id.uuidString, "room": record.roomName,
             "kind": record.kind, "sealed": iso(record.sealedAt),
             "sha256": record.sealHash ?? NSNull(),
             "photos": record.shots.map {
                 ["file": "blobs/condition/\(record.id.uuidString)/"
                     + "\($0.id.uuidString).jpg",
                  "tag": $0.tag, "note": $0.note, "at": iso($0.at)]
             }]
        }
        return try? JSONSerialization.data(
            withJSONObject: [
                "exported": ISO8601DateFormatter().string(from: Date()),
                "app": "Theseus",
                "rooms": roomRows,
                "things": thingRows,
                "storage": spotRows,
                "condition_records": recordRows,
            ],
            options: [.prettyPrinted, .sortedKeys])
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-",
                               options: .regularExpression)
    }
}
