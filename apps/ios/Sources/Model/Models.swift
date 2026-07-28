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

    /// One-line AI description ("blue ceramic mug with a chipped
    /// handle") — written by automatic AI naming, searched by
    /// SmartSearch, so descriptive queries work fully offline after
    /// the one capture-time call.
    var aiSummary: String?

    // value tracking (optional — powers the insurance report totals).
    // The receipt photo itself is a blob (Store.receiptURL).
    var price: Double?
    /// Where the value came from: "" (user-typed), "ai" (estimated),
    /// or "receipt" (read off the receipt photo — documented, the
    /// strongest provenance).
    var priceSource: String = ""
    /// From the receipt when it could be read — turns "worth about"
    /// into "bought on".
    var purchaseDate: Date?

    // insurance dossier (all optional, all additive migrations)
    var serialNumber: String?
    var warrantyUntil: Date?
    var warrantyNote: String?

    /// Lives inside a StorageSpot (box/closet/drawer) instead of — or
    /// as well as — sitting at a mapped position. Position-less things
    /// (widthM == 0 && hits == 0 convention not needed: hasPosition
    /// below) exist for itemized box contents.
    var storageID: UUID?
    /// False for things created by itemizing a box photo — they have a
    /// home (the spot) but no floor-plan pin.
    var hasPosition: Bool = true

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
         aiSummary ?? "", barcode ?? ""]
            .joined(separator: " ").lowercased()
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

/// A storage location with contents: box, bin, closet, drawer, shelf.
/// This is the half of "where is my X" that no camera scan answers —
/// things that live INSIDE other things. Spots nest (closet > shelf >
/// box) via parentID, carry an optional photo of their contents
/// (Store.spotPhotoURL), and can be labelled with a printable QR that
/// deep-links back to the spot (theseus://spot/<uuid>).
@Model
final class StorageSpot {
    var id: UUID = UUID()
    var name: String = "Box"
    var kind: String = "box"    // box|bin|closet|drawer|shelf|cabinet|other
    var note: String = ""
    var createdAt: Date = Date()
    var roomID: UUID?           // loose link — survives room deletion
    var parentID: UUID?         // nesting; nil = top level

    init(name: String, kind: String, roomID: UUID? = nil,
         parentID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.roomID = roomID
        self.parentID = parentID
        self.createdAt = Date()
    }

    var kindSymbol: String {
        switch kind {
        case "box": return "shippingbox"
        case "bin": return "archivebox"
        case "closet": return "door.left.hand.closed"
        case "drawer": return "tray"
        case "shelf": return "books.vertical"
        case "cabinet": return "cabinet"
        default: return "square.dashed"
        }
    }
}

/// One evidence walkthrough of a room — the rental-deposit feature.
/// A record is a set of dated, captioned photos (walls, floor, damage
/// close-ups); sealing it computes a SHA-256 over every photo and its
/// metadata, so the record provably hasn't been edited after the fact.
/// Move-out repeats the walkthrough and the pair exports side-by-side.
@Model
final class ConditionRecord {
    var id: UUID = UUID()
    var roomID: UUID?
    var roomName: String = "Room"   // survives room deletion — evidence
    var kind: String = "movein"     // movein|moveout|checkup
    var startedAt: Date = Date()
    var sealedAt: Date?
    var sealHash: String?

    @Relationship(deleteRule: .cascade, inverse: \ConditionShot.record)
    var shots: [ConditionShot] = []

    init(roomID: UUID?, roomName: String, kind: String) {
        self.id = UUID()
        self.roomID = roomID
        self.roomName = roomName
        self.kind = kind
        self.startedAt = Date()
    }

    var isSealed: Bool { sealedAt != nil }

    var kindTitle: String {
        switch kind {
        case "movein": return "Move-in"
        case "moveout": return "Move-out"
        default: return "Check-up"
        }
    }
}

/// One photo in a condition record. The image bytes live in
/// Store.conditionShotURL; this row is the caption and the clock.
@Model
final class ConditionShot {
    var id: UUID = UUID()
    var at: Date = Date()
    var tag: String = ""        // "North wall", "Damage close-up", …
    var note: String = ""
    var record: ConditionRecord?

    init(tag: String, note: String = "") {
        self.id = UUID()
        self.at = Date()
        self.tag = tag
        self.note = note
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
