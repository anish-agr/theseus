// SwiftData entities — see docs/DATA-MODEL.md for the full contract.
// Rule: queryable metadata lives here; large opaque bytes (world maps,
// grids, photos) live in files and are referenced by id (see Store).
import Foundation
import SwiftData

@Model
final class Place {
    var id: UUID = UUID()
    var name: String = "Home"
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Room.place)
    var rooms: [Room] = []

    init(name: String = "Home") {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
    }
}

/// One contiguous mapped space with its own coordinate frame. This is
/// the unit of relocalization: ARKit can hold exactly one ARWorldMap at
/// a time, so "which room am I in" is answered by which map is loaded.
@Model
final class Room {
    var id: UUID = UUID()
    var name: String = "Room"
    var createdAt: Date = Date()
    var lastScannedAt: Date = Date()

    // grid geometry (mirrors NavCore.OccupancyGrid)
    var cellSize: Double = 0.05
    var gridWidth: Int = 240
    var gridHeight: Int = 240
    var originX: Double = -6.0
    var originY: Double = -6.0

    var coverage: Double = 0          // 0-1 of reachable floor mapped
    var floorAreaM2: Double = 0
    var hasWorldMap: Bool = false

    var place: Place?

    @Relationship(deleteRule: .cascade, inverse: \Thing.room)
    var things: [Thing] = []

    @Relationship(deleteRule: .cascade, inverse: \Doorway.room)
    var doorways: [Doorway] = []

    @Relationship(deleteRule: .cascade, inverse: \ScanSession.room)
    var sessions: [ScanSession] = []

    init(name: String, cellSize: Double = 0.05, gridWidth: Int = 240,
         gridHeight: Int = 240, originX: Double = -6.0,
         originY: Double = -6.0) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.lastScannedAt = Date()
        self.cellSize = cellSize
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.originX = originX
        self.originY = originY
    }

    var promotedThings: [Thing] {
        things.filter { $0.promoted }
    }
}

/// An edge in the house graph. v1 records it and points at it
/// ("Kitchen is through that door"); metric cross-room routing later.
@Model
final class Doorway {
    var id: UUID = UUID()
    var positionX: Double = 0
    var positionY: Double = 0
    var connectsToRoomID: UUID?
    var room: Room?

    init(positionX: Double, positionY: Double,
         connectsToRoomID: UUID? = nil) {
        self.id = UUID()
        self.positionX = positionX
        self.positionY = positionY
        self.connectsToRoomID = connectsToRoomID
    }
}

/// An object in the world: what it is, how big it is, where it is,
/// what it looks like, and when it was last there.
@Model
final class Thing {
    var id: UUID = UUID()

    // identity
    var displayName: String = "Object"
    var autoLabel: String = ""
    var autoConfidence: Double = 0
    var userNamed: Bool = false        // once true, never auto-overwrite
    var category: String = "object"
    var recognizedText: String = ""    // OCR — searchable
    var barcode: String?

    // where
    var positionX: Double = 0
    var positionY: Double = 0
    var heightM: Double = 0            // centre height above floor

    // how big (measured, see ObjectCapture.estimateSize)
    var widthM: Double = 0
    var sizeHeightM: Double = 0
    var sizeConfidence: Double = 0

    // recognition
    var featurePrint: Data?            // Vision fingerprint, re-ID
    var clipEmbedding: Data?           // set when the CLIP model exists

    // registry bookkeeping (mirrors NavCore.WaypointRegistry)
    var confidence: Double = 0
    var hits: Int = 0
    var promoted: Bool = false

    var firstSeenAt: Date = Date()
    var lastSeenAt: Date = Date()
    var isMissing: Bool = false

    var room: Room?

    @Relationship(deleteRule: .cascade, inverse: \Sighting.thing)
    var sightings: [Sighting] = []

    init(displayName: String, autoLabel: String, autoConfidence: Double,
         category: String, positionX: Double, positionY: Double,
         heightM: Double, widthM: Double, sizeHeightM: Double,
         sizeConfidence: Double) {
        self.id = UUID()
        self.displayName = displayName
        self.autoLabel = autoLabel
        self.autoConfidence = autoConfidence
        self.category = category
        self.positionX = positionX
        self.positionY = positionY
        self.heightM = heightM
        self.widthM = widthM
        self.sizeHeightM = sizeHeightM
        self.sizeConfidence = sizeConfidence
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
    }

    /// "12 × 9 cm" — the inventory's most-requested column.
    var sizeDescription: String {
        guard widthM > 0 else { return "size unknown" }
        let w = widthM * 100
        let h = sizeHeightM * 100
        if w >= 100 || h >= 100 {
            return String(format: "%.2f × %.2f m", widthM, sizeHeightM)
        }
        return String(format: "%.0f × %.0f cm", w, h)
    }

    var searchHaystack: String {
        [displayName, autoLabel, recognizedText, category,
         barcode ?? ""].joined(separator: " ").lowercased()
    }
}

/// One observation of a Thing. The history that lets the app say
/// "your keys were on the hall table yesterday".
@Model
final class Sighting {
    var id: UUID = UUID()
    var at: Date = Date()
    var positionX: Double = 0
    var positionY: Double = 0
    var confidence: Double = 0
    var movedSincePrevious: Bool = false
    var thing: Thing?

    init(positionX: Double, positionY: Double, confidence: Double,
         movedSincePrevious: Bool) {
        self.id = UUID()
        self.at = Date()
        self.positionX = positionX
        self.positionY = positionY
        self.confidence = confidence
        self.movedSincePrevious = movedSincePrevious
    }
}

@Model
final class ScanSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var coverageDelta: Double = 0
    var thingsAdded: Int = 0
    var traceFilename: String?
    var room: Room?

    init() {
        self.id = UUID()
        self.startedAt = Date()
    }
}
