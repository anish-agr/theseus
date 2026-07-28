// Your maps. Each card is a room: floor plan thumbnail, how much of it
// is mapped, how many things are in it, when you last scanned.
import NavCore
import SwiftData
import SwiftUI

struct RoomsView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Query(sort: \Room.lastScannedAt, order: .reverse) private var rooms: [Room]
    @Query private var places: [Place]
    @Binding var activeRoom: Room?
    @Binding var selectedTab: Int
    @State private var newRoomName = ""
    @State private var showingNewRoom = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if rooms.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(rooms) { room in
                            NavigationLink {
                                RoomDetailView(room: room,
                                               activeRoom: $activeRoom,
                                               selectedTab: $selectedTab)
                            } label: {
                                RoomRow(room: room)
                            }
                        }
                        .onDelete(perform: deleteRooms)
                    }
                }
            }
            .navigationTitle("Rooms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewRoom = true
                    } label: {
                        Label("New room", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .alert("Name this room", isPresented: $showingNewRoom) {
                TextField("Kitchen", text: $newRoomName)
                Button("Start scanning", action: createRoom)
                Button("Cancel", role: .cancel) { newRoomName = "" }
            } message: {
                Text("You'll sweep the phone around to map it.")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.cyan)
            Text("Map your first room")
                .font(.title2.bold())
            Text("Sweep your phone around the space. Then point at "
                 + "anything for a moment and Theseus will remember "
                 + "where it is.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                showingNewRoom = true
            } label: {
                Text("Scan a room").frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func createRoom() {
        let name = newRoomName.trimmingCharacters(in: .whitespaces)
        let room = Room(name: name.isEmpty ? "Room" : name,
                        cellSize: NavEngine.cell,
                        gridWidth: Int(NavEngine.mapSide / NavEngine.cell),
                        gridHeight: Int(NavEngine.mapSide / NavEngine.cell),
                        originX: -NavEngine.mapSide / 2,
                        originY: -NavEngine.mapSide / 2)
        room.place = places.first
        context.insert(room)
        newRoomName = ""
        engine.resetForNewRoom(id: room.id)
        activeRoom = room
        selectedTab = 1
    }

    private func deleteRooms(at offsets: IndexSet) {
        for index in offsets {
            let room = rooms[index]
            for thing in room.things {
                Store.deleteThingBlobs(thing.id)
            }
            Store.deleteRoomBlobs(room.id)
            if activeRoom?.id == room.id { activeRoom = nil }
            context.delete(room)
        }
    }
}

struct RoomRow: View {
    let room: Room

    var body: some View {
        HStack(spacing: 14) {
            FloorPlanThumbnail(room: room)
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name).font(.headline)
                Text("\(room.things.count) things · "
                     + String(format: "%.1f m²", room.floorAreaM2))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ProgressView(value: room.coverage)
                        .frame(width: 70)
                    Text("\(Int(room.coverage * 100))% mapped")
                        .font(.caption)
                        .foregroundStyle(room.coverage > 0.6
                                         ? .green : .orange)
                }
                Text(room.lastScannedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Cached render of the saved grid for lists — the decode happens once
/// per scan date off the main thread, not on every Canvas draw.
struct FloorPlanThumbnail: View {
    let room: Room
    @State private var cells: [UInt8] = []
    @State private var gridW = 0
    @State private var gridH = 0

    var body: some View {
        Canvas { ctx, size in
            guard gridW > 0, cells.count == gridW * gridH else {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.gray.opacity(0.2)))
                return
            }
            let sx = size.width / CGFloat(gridW)
            let sy = size.height / CGFloat(gridH)
            for y in stride(from: 0, to: gridH, by: 2) {
                for x in stride(from: 0, to: gridW, by: 2) {
                    let s = cells[y * gridW + x]
                    guard s != 0 else { continue }
                    let rect = CGRect(x: CGFloat(x) * sx,
                                      y: size.height - CGFloat(y + 1) * sy,
                                      width: sx * 2, height: sy * 2)
                    ctx.fill(Path(rect), with: .color(
                        s == 1 ? Color(red: 0.10, green: 0.28, blue: 0.28)
                               : Color(red: 0.85, green: 0.65, blue: 0.25)))
                }
            }
        }
        .background(Color.black.opacity(0.6))
        .task(id: room.lastScannedAt) {
            let roomID = room.id
            let loaded: ([UInt8], Int, Int)? = await Task.detached {
                guard let grid = Store.loadGrid(roomID) else { return nil }
                var snap = [UInt8](repeating: 0,
                                   count: grid.width * grid.height)
                for i in 0..<grid.lo.count {
                    if grid.lo[i] >= LO_OCC {
                        snap[i] = 2
                    } else if grid.lo[i] <= LO_FREE {
                        snap[i] = 1
                    }
                }
                return (snap, grid.width, grid.height)
            }.value
            if let (snap, w, h) = loaded {
                cells = snap
                gridW = w
                gridH = h
            }
        }
    }
}

struct RoomDetailView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.modelContext) private var context
    @Bindable var room: Room
    @Binding var activeRoom: Room?
    @Binding var selectedTab: Int
    @State private var showFit = false
    @State private var showMeasure = false

    var body: some View {
        List {
            Section {
                FloorPlanThumbnail(room: room)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .listRowInsets(EdgeInsets())
            }
            Section("This room") {
                LabeledContent("Things", value: "\(room.things.count)")
                LabeledContent("Floor area",
                               value: String(format: "%.1f m²",
                                             room.floorAreaM2))
                LabeledContent("Mapped",
                               value: "\(Int(room.coverage * 100))%")
                LabeledContent("Last scanned") {
                    Text(room.lastScannedAt,
                         format: .dateTime.day().month().hour().minute())
                }
            }
            Section {
                Button {
                    activeRoom = room
                    engine.makeActive(room)
                    selectedTab = 1
                } label: {
                    Label("Continue scanning", systemImage: "camera.viewfinder")
                }
                NavigationLink {
                    ChangesView(room: room)
                } label: {
                    Label("What changed", systemImage: "clock.arrow.circlepath")
                }
            }
            Section("Things here") {
                ForEach(room.things.sorted { $0.lastSeenAt > $1.lastSeenAt }) {
                    thing in
                    NavigationLink {
                        ThingDetailView(thing: thing,
                                        activeRoom: $activeRoom,
                                        selectedTab: $selectedTab)
                    } label: {
                        ThingRow(thing: thing, showRoom: false)
                    }
                }
            }
        }
        .navigationTitle(room.name)
        .toolbar {
            // occasional-use tools live behind a menu, not the main list
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showMeasure = true
                    } label: {
                        Label("Measure", systemImage: "ruler")
                    }
                    Button {
                        showFit = true
                    } label: {
                        Label("Will it fit?",
                              systemImage: "arrow.left.and.right")
                    }
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .sheet(isPresented: $showFit) {
            FitThroughView(room: room)
        }
        .sheet(isPresented: $showMeasure) {
            MeasureView(room: room)
        }
    }
}
