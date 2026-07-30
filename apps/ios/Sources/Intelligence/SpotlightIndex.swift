// Every captured thing is indexed in iOS Spotlight, so the phone's own
// home-screen search finds "keys" without opening the app — swipe down,
// type, tap, and Theseus opens straight to locating it. For a lost-item
// tool this is the shortest possible path from panic to answer.
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightIndex {
    static let domain = "dev.anish.theseus.things"

    /// `location` overrides the room line — used for things that live
    /// in a storage spot ("In Moving Box 3") rather than at a pin.
    static func index(_ thing: Thing, location: String? = nil) {
        let attrs = CSSearchableItemAttributeSet(contentType: .item)
        attrs.title = thing.displayName
        var parts: [String] = []
        if let location {
            parts.append(location)
        } else if let room = thing.room {
            // no article: room names are free text ("Anish"), and
            // "In the Anish" reads wrong (field test 6)
            parts.append("In \(room.name)")
        }
        if thing.widthM > 0 { parts.append(thing.sizeDescription) }
        parts.append("Theseus knows where this is")
        attrs.contentDescription = parts.joined(separator: " · ")
        if !thing.recognizedText.isEmpty {
            attrs.keywords = [thing.autoLabel, thing.recognizedText]
        } else if !thing.autoLabel.isEmpty {
            attrs.keywords = [thing.autoLabel]
        }
        attrs.thumbnailData = try? Data(
            contentsOf: Store.thumbURL(thing.id))

        let item = CSSearchableItem(
            uniqueIdentifier: thing.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attrs)
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func remove(_ id: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [id.uuidString])
    }
}
