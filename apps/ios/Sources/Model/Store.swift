// Blob storage: the bytes too big or too opaque for SwiftData.
// The grid layout mirrors the Python engine's on-disk format
// (theseus-grid/1) on purpose — a phone scan opens in the desktop
// viewer, and vice versa.
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
        // ARWorldMaps are the bulk of on-disk size (10-15 MB each raw);
        // LZFSE roughly halves them for a few ms of work
        let out = (try? (data as NSData).compressed(
            using: .lzfse) as Data) ?? data
        try out.write(to: worldMapURL(roomID), options: .atomic)
    }

    static func loadWorldMap(_ roomID: UUID) -> ARWorldMap? {
        guard let raw = try? Data(contentsOf: worldMapURL(roomID)) else {
            return nil
        }
        // old installs saved uncompressed maps — fall back on failure
        let data = (try? (raw as NSData).decompressed(
            using: .lzfse) as Data) ?? raw
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

    private static let thumbCache = NSCache<NSUUID, UIImage>()

    static func saveThumb(_ image: UIImage, thingID: UUID) {
        // 512 px is plenty for cards, reports and the AI; full-res
        // crops were a silent disk (and scroll-decode) hog
        let maxSide: CGFloat = 512
        var out = image
        let side = max(image.size.width, image.size.height)
        if side > maxSide {
            let scale = maxSide / side
            let size = CGSize(width: image.size.width * scale,
                              height: image.size.height * scale)
            out = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        guard let data = out.jpegData(compressionQuality: 0.75) else {
            return
        }
        try? data.write(to: thumbURL(thingID), options: .atomic)
        thumbCache.setObject(out, forKey: thingID as NSUUID)
    }

    static func loadThumb(_ thingID: UUID) -> UIImage? {
        if let cached = thumbCache.object(forKey: thingID as NSUUID) {
            return cached
        }
        guard let image = UIImage(
            contentsOfFile: thumbURL(thingID).path) else { return nil }
        thumbCache.setObject(image, forKey: thingID as NSUUID)
        return image
    }

    // ---- receipts --------------------------------------------------------

    static func receiptURL(_ thingID: UUID) -> URL {
        thingsDir().appendingPathComponent(
            "\(thingID.uuidString)-receipt.jpg")
    }

    static func saveReceipt(_ data: Data, thingID: UUID) {
        try? data.write(to: receiptURL(thingID), options: .atomic)
    }

    static func loadReceipt(_ thingID: UUID) -> UIImage? {
        UIImage(contentsOfFile: receiptURL(thingID).path)
    }

    static func hasReceipt(_ thingID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: receiptURL(thingID).path)
    }

    // ---- storage spots ---------------------------------------------------

    static func spotPhotoURL(_ spotID: UUID) -> URL {
        thingsDir().appendingPathComponent(
            "spot-\(spotID.uuidString).jpg")
    }

    static func saveSpotPhoto(_ data: Data, spotID: UUID) {
        try? data.write(to: spotPhotoURL(spotID), options: .atomic)
    }

    static func loadSpotPhoto(_ spotID: UUID) -> UIImage? {
        UIImage(contentsOfFile: spotPhotoURL(spotID).path)
    }

    static func deleteSpotBlobs(_ spotID: UUID) {
        try? FileManager.default.removeItem(at: spotPhotoURL(spotID))
    }

    // ---- condition records (rental-deposit evidence) ---------------------

    static func conditionDir(_ recordID: UUID) -> URL {
        let dir = root.appendingPathComponent(
            "condition/\(recordID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func conditionShotURL(recordID: UUID, shotID: UUID) -> URL {
        conditionDir(recordID)
            .appendingPathComponent("\(shotID.uuidString).jpg")
    }

    static func saveConditionShot(_ data: Data, recordID: UUID,
                                  shotID: UUID) {
        try? data.write(to: conditionShotURL(recordID: recordID,
                                             shotID: shotID),
                        options: .atomic)
    }

    static func loadConditionShot(recordID: UUID,
                                  shotID: UUID) -> UIImage? {
        UIImage(contentsOfFile: conditionShotURL(
            recordID: recordID, shotID: shotID).path)
    }

    static func deleteConditionBlobs(_ recordID: UUID) {
        try? FileManager.default.removeItem(at: conditionDir(recordID))
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
        thumbCache.removeObject(forKey: thingID as NSUUID)
        try? FileManager.default.removeItem(at: thumbURL(thingID))
        try? FileManager.default.removeItem(at: receiptURL(thingID))
        SpotlightIndex.remove(thingID)
    }

    /// Settings → "Delete everything". Removes the whole blob tree; the
    /// caller separately empties the SwiftData store.
    static func deleteAllBlobs() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Where the space actually goes — the honest answer to "why is
    /// this 32 MB". (Room maps are ARWorldMaps; they dominate.)
    static func bytesBreakdown() -> [(label: String, bytes: Int64)] {
        func dirBytes(_ url: URL) -> Int64 {
            guard let e = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey])
            else { return 0 }
            var total: Int64 = 0
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(
                    forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total
        }
        return [
            ("Room maps & grids",
             dirBytes(root.appendingPathComponent("rooms"))),
            ("Item photos & receipts", dirBytes(thingsDir())),
            ("Condition records",
             dirBytes(root.appendingPathComponent("condition"))),
            ("Diagnostic traces", dirBytes(tracesDir())),
        ]
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
