// Blob storage: the bytes too big or too opaque for SwiftData.
// Layout is documented in docs/DATA-MODEL.md and mirrors the Python
// engine's on-disk grid format (theseus-grid/1) on purpose — a phone
// scan opens in the desktop viewer, and vice versa.
import ARKit
import Foundation
import NavCore
import UIKit

enum Store {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Theseus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    static func roomDir(_ id: UUID) -> URL {
        let dir = root.appendingPathComponent("rooms/\(id.uuidString)",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    static func thingsDir() -> URL {
        let dir = root.appendingPathComponent("things", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    static func tracesDir() -> URL {
        let dir = root.appendingPathComponent("traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    // ---- ARWorldMap ------------------------------------------------------

    static func worldMapURL(_ roomID: UUID) -> URL {
        roomDir(roomID).appendingPathComponent("worldmap.bin")
    }

    static func saveWorldMap(_ map: ARWorldMap, roomID: UUID) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map,
                                                    requiringSecureCoding: true)
        try data.write(to: worldMapURL(roomID), options: .atomic)
    }

    static func loadWorldMap(_ roomID: UUID) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL(roomID)) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARWorldMap.self, from: data)
    }

    // ---- occupancy grid (theseus-grid/1, same as the Python engine) ------

    static func gridURL(_ roomID: UUID) -> URL {
        roomDir(roomID).appendingPathComponent("grid.bin")
    }

    /// Archive the current grid before a re-scan so change detection has
    /// a "yesterday" to compare against.
    static func archiveGrid(_ roomID: UUID) {
        let current = gridURL(roomID)
        guard FileManager.default.fileExists(atPath: current.path) else {
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = roomDir(roomID)
            .appendingPathComponent("grid-\(stamp).bin")
        try? FileManager.default.copyItem(at: current, to: dest)
        pruneGridHistory(roomID, keep: 3)
    }

    static func gridHistory(_ roomID: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: roomDir(roomID), includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("grid-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func pruneGridHistory(_ roomID: UUID, keep: Int) {
        let history = gridHistory(roomID)
        guard history.count > keep else { return }
        for url in history.dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func saveGrid(_ grid: OccupancyGrid, roomID: UUID) throws {
        let data = try encodeGrid(grid)
        try data.write(to: gridURL(roomID), options: .atomic)
    }

    static func loadGrid(_ roomID: UUID) -> OccupancyGrid? {
        guard let data = try? Data(contentsOf: gridURL(roomID)) else {
            return nil
        }
        return try? decodeGrid(data)
    }

    static func loadGrid(url: URL) -> OccupancyGrid? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decodeGrid(data)
    }

    static func encodeGrid(_ grid: OccupancyGrid) throws -> Data {
        let snap = toSnapshot(grid)
        var labels: [String: String] = [:]
        for (k, v) in snap.labels {
            labels[String(k)] = v
        }
        let obj: [String: Any] = [
            "schema": snap.schema,
            "w": snap.w,
            "h": snap.h,
            "cell": snap.cell,
            "origin": [snap.origin.x, snap.origin.y],
            "states": snap.states,
            "labels": labels,
        ]
        return try JSONSerialization.data(withJSONObject: obj,
                                          options: [.sortedKeys])
    }

    static func decodeGrid(_ data: Data) throws -> OccupancyGrid {
        guard let obj = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let schema = obj["schema"] as? String,
              let w = obj["w"] as? Int, let h = obj["h"] as? Int,
              let cell = obj["cell"] as? Double,
              let origin = obj["origin"] as? [Double],
              let states = obj["states"] as? [Int]
        else {
            throw SnapshotError.badLength
        }
        var labels: [Int: String] = [:]
        for (k, v) in (obj["labels"] as? [String: String] ?? [:]) {
            if let i = Int(k) { labels[i] = v }
        }
        let snap = GridSnapshot(schema: schema, w: w, h: h, cell: cell,
                                origin: Vec(origin[0], origin[1]),
                                states: states, labels: labels)
        return try fromSnapshot(snap)
    }

    // ---- thumbnails ------------------------------------------------------

    static func thumbURL(_ thingID: UUID) -> URL {
        thingsDir().appendingPathComponent("\(thingID.uuidString).jpg")
    }

    static func saveThumb(_ image: UIImage, thingID: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            return
        }
        try? data.write(to: thumbURL(thingID), options: .atomic)
    }

    static func loadThumb(_ thingID: UUID) -> UIImage? {
        UIImage(contentsOfFile: thumbURL(thingID).path)
    }

    // ---- traces ----------------------------------------------------------

    static func saveTrace(_ jsonl: String, sessionID: UUID) -> URL? {
        let url = tracesDir()
            .appendingPathComponent("\(sessionID.uuidString).jsonl")
        try? jsonl.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // ---- deletion --------------------------------------------------------

    static func deleteRoomBlobs(_ roomID: UUID) {
        try? FileManager.default.removeItem(at: roomDir(roomID))
    }

    static func deleteThingBlobs(_ thingID: UUID) {
        try? FileManager.default.removeItem(at: thumbURL(thingID))
    }

    /// Settings → "Delete everything". Removes the whole blob tree; the
    /// caller separately empties the SwiftData store.
    static func deleteAllBlobs() {
        try? FileManager.default.removeItem(at: root)
    }

    static func totalBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in e {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
