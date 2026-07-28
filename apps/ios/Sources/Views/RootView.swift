// Three tabs — Rooms (your maps), Scan (the verb), Things (everything
// you own that the app has seen). Guidance is a mode, not a tab: it
// takes the whole screen when active.
import SwiftData
import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Query private var places: [Place]
    @State private var selectedTab = 0
    @State private var activeRoom: Room?

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                RoomsView(activeRoom: $activeRoom, selectedTab: $selectedTab)
                    .tabItem { Label("Rooms", systemImage: "square.grid.2x2") }
                    .tag(0)

                ScanView(room: $activeRoom)
                    .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                    .tag(1)

                ThingsView(activeRoom: $activeRoom, selectedTab: $selectedTab)
                    .tabItem { Label("Things", systemImage: "shippingbox") }
                    .tag(2)
            }
            .tint(.cyan)

            if engine.isGuiding {
                GuidanceView()
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.isGuiding)
        .onAppear(perform: ensurePlace)
    }

    /// Every install has exactly one implicit Place until multi-home
    /// support earns its keep.
    private func ensurePlace() {
        if places.isEmpty {
            context.insert(Place(name: "Home"))
        }
    }
}
