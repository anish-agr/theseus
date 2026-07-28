// "Will this couch make the turn?" — the corridor-width solver with a
// number attached. Answers with the narrowest point on the route, not
// just yes/no, because the useful part is knowing WHERE it pinches.
// Lives behind the room's Tools menu — occasional-use by design.
import NavCore
import SwiftUI

struct FitThroughView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.dismiss) private var dismiss
    let room: Room
    @State private var widthCm: Double = 80
    @State private var fromThing: Thing?   // nil = my position
    @State private var target: Thing?
    @State private var result: (ok: Bool, pinch: Vec?,
                                narrowest: Double)?
    @State private var noRoute = false

    /// Pose is only meaningful when this room's map is live in the AR
    /// session; otherwise measure between two logged things instead.
    private var roomActive: Bool { engine.currentRoomID == room.id }

    var body: some View {
        NavigationStack {
            Form {
                Section("How wide is it?") {
                    HStack {
                        Slider(value: $widthCm, in: 20...200, step: 5)
                        Text("\(Int(widthCm)) cm")
                            .monospacedDigit().frame(width: 64)
                    }
                }
                Section("Route") {
                    Picker("From", selection: $fromThing) {
                        if roomActive {
                            Text("My position").tag(nil as Thing?)
                        }
                        ForEach(room.things.filter(\.promoted)) { thing in
                            Text(thing.displayName).tag(thing as Thing?)
                        }
                    }
                    Picker("To", selection: $target) {
                        Text("Pick a thing").tag(nil as Thing?)
                        ForEach(room.things.filter(\.promoted)) { thing in
                            Text(thing.displayName).tag(thing as Thing?)
                        }
                    }
                }
                Section {
                    Button("Check the route") { check() }
                        .disabled(target == nil
                                  || (!roomActive && fromThing == nil))
                }
                if noRoute {
                    Label("No walkable route between those points",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let result {
                    Section("Verdict") {
                        Label(result.ok ? "It fits" : "It will not fit",
                              systemImage: result.ok
                              ? "checkmark.circle.fill"
                              : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .font(.headline)
                        LabeledContent(
                            "Narrowest point",
                            value: String(format: "%.2f m",
                                          result.narrowest))
                        if let pinch = result.pinch {
                            LabeledContent(
                                "Pinch located at",
                                value: String(format: "%.1f, %.1f m",
                                              pinch.x, pinch.y))
                        }
                        Text("Measured as a swept disc, which is "
                             + "conservative for long objects cornering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Will it fit?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if !roomActive, fromThing == nil {
                    fromThing = room.things.first(where: \.promoted)
                }
            }
        }
    }

    private func check() {
        guard let target else { return }
        let grid: OccupancyGrid?
        if roomActive {
            grid = engine.grid
        } else {
            grid = Store.loadGrid(room.id)
        }
        guard let grid else { return }
        let start: Vec
        if let fromThing {
            start = Vec(fromThing.positionX, fromThing.positionY)
        } else {
            start = Vec(engine.pose.x, engine.pose.y)
        }
        grid.refreshClearance(force: true)
        guard let res = plan(grid: grid,
                             start: grid.worldToCell(start),
                             goal: grid.worldToCell(
                                Vec(target.positionX, target.positionY)),
                             params: engine.params) else {
            result = nil
            noRoute = true
            return
        }
        noRoute = false
        let sm = smooth(grid: grid, cells: res.cells,
                        params: engine.params)
        result = fitsThrough(grid: grid, pts: sm, widthM: widthCm / 100)
    }
}
