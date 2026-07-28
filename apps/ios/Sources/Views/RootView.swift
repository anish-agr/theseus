// Five tabs — Home (the hub), Scan (the verb), Stuff (everything you
// own that the app has seen), Rooms (your maps), Tools (occasional-use
// utilities). Guidance is a mode, not a tab: it takes the whole screen
// only while an actual route is being walked.
import CoreSpotlight
import SwiftData
import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Query private var places: [Place]
    @Query private var allThings: [Thing]
    @State private var selectedTab = 0
    @State private var activeRoom: Room?

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView(activeRoom: $activeRoom,
                         selectedTab: $selectedTab)
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(0)

                ScanView(room: $activeRoom, selectedTab: $selectedTab)
                    .tabItem {
                        Label("Scan", systemImage: "camera.viewfinder")
                    }
                    .tag(1)

                ThingsView(activeRoom: $activeRoom,
                           selectedTab: $selectedTab)
                    .tabItem { Label("Stuff", systemImage: "shippingbox") }
                    .tag(2)

                RoomsView(activeRoom: $activeRoom,
                          selectedTab: $selectedTab)
                    .tabItem {
                        Label("Rooms", systemImage: "square.grid.2x2")
                    }
                    .tag(3)

                ToolsView()
                    .tabItem {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }
                    .tag(4)
            }
            .tint(.cyan)

            if engine.isGuiding {
                GuidanceView()
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }

            if let problem = engine.routeProblem {
                routeProblemToast(problem)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.isGuiding)
        .animation(.easeInOut(duration: 0.25),
                   value: engine.routeProblem != nil)
        .onAppear(perform: ensurePlace)
        // Tapping a Theseus result in the iPhone's own Spotlight search
        // lands here: open the app straight into locating that thing.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let idString = activity.userInfo?[
                CSSearchableItemActivityIdentifier] as? String,
                let id = UUID(uuidString: idString),
                let thing = allThings.first(where: { $0.id == id }),
                let room = thing.room else { return }
            activeRoom = room
            engine.makeActive(room)
            engine.locateTarget = LocateTarget(
                thingID: thing.id, name: thing.displayName,
                x: thing.positionX, y: thing.positionY)
            selectedTab = 1
        }
    }

    /// A route that cannot exist yet is a toast, not a takeover.
    private func routeProblemToast(_ problem: String) -> some View {
        VStack {
            Spacer()
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .padding(14)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .padding(.bottom, 70)
                .task {
                    try? await Task.sleep(for: .seconds(3.5))
                    engine.routeProblem = nil
                }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(20)
    }

    /// Every install has exactly one implicit Place until multi-home
    /// support earns its keep.
    private func ensurePlace() {
        if places.isEmpty {
            context.insert(Place(name: "Home"))
        }
    }
}
