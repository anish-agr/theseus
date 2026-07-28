// Theseus — Ariadne v0. Scan a room into an occupancy map (no LiDAR
// needed), tap a destination on the minimap, get guided with arrow +
// voice + haptics while D* Lite reroutes around changes live.
import SwiftUI

@main
struct TheseusApp: App {
    @StateObject private var engine = NavEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}
