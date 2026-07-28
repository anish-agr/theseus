// Theseus — a spatial memory for the places you live.
// Scan a room, point at things to remember them, then ask where they
// are. See docs/PRD.md for the product argument.
import SwiftData
import SwiftUI

@main
struct TheseusApp: App {
    @StateObject private var engine = NavEngine()
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: Place.self, Room.self, Thing.self, Sighting.self,
                Doorway.self, ScanSession.self, StorageSpot.self,
                ConditionRecord.self, ConditionShot.self)
        } catch {
            // A store we cannot open is unrecoverable; an in-memory
            // fallback at least lets the user reach Settings -> reset
            // instead of facing a launch loop.
            container = try! ModelContainer(
                for: Place.self, Room.self, Thing.self, Sighting.self,
                Doorway.self, ScanSession.self, StorageSpot.self,
                ConditionRecord.self, ConditionShot.self,
                configurations: ModelConfiguration(
                    isStoredInMemoryOnly: true))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(.brandThread)
        }
        .modelContainer(container)
    }
}
