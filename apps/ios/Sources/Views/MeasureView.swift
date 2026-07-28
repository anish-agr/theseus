// Measure — tap two points on the floor plan and get three numbers:
// straight-line distance, actual walking distance (A* over the map),
// and the narrowest corridor along that route. Object sizes are already
// measured at capture; this covers the "how far / how wide" questions.
import NavCore
import SwiftUI

struct MeasureView: View {
    @EnvironmentObject var engine: NavEngine
    @Environment(\.dismiss) private var dismiss
    let room: Room

    @State private var grid: OccupancyGrid?
    @State private var snapshot: [UInt8] = []
    @State private var pointA: Vec?
    @State private var pointB: Vec?
    @State private var straight: Double?
    @State private var walking: Double?
    @State private var narrowest: Double?
    @State private var noRoute = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    planCanvas(size: geo.size)
                        .contentShape(Rectangle())
                        .onTapGesture { tap in
                            place(tap, in: geo.size)
                        }
                }
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal)

                if let straight {
                    VStack(spacing: 8) {
                        LabeledContent("Straight line",
                                       value: format(straight))
                        if let walking {
                            LabeledContent("Walking route",
                                           value: format(walking))
                        }
                        if let narrowest {
                            LabeledContent("Narrowest squeeze",
                                           value: format(narrowest))
                        }
                        if noRoute {
                            Label("No walkable route between those points",
                                  systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Measure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { clear() }
                        .disabled(pointA == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { load() }
        }
    }

    private var prompt: String {
        if pointA == nil { return "Tap the first point" }
        if pointB == nil { return "Tap the second point" }
        return "Tap again to start over"
    }

    private func format(_ m: Double) -> String {
        m < 1 ? String(format: "%.0f cm", m * 100)
              : String(format: "%.2f m", m)
    }

    // ---- plan rendering / hit mapping ------------------------------------

    private func load() {
        let g: OccupancyGrid?
        if engine.currentRoomID == room.id {
            g = engine.grid
        } else {
            g = Store.loadGrid(room.id)
        }
        guard let g else { return }
        grid = g
        var snap = [UInt8](repeating: 0, count: g.width * g.height)
        for i in 0..<g.lo.count {
            if g.lo[i] >= LO_OCC {
                snap[i] = 2
            } else if g.lo[i] <= LO_FREE {
                snap[i] = 1
            }
        }
        snapshot = snap
    }

    private func scale(for size: CGSize, grid: OccupancyGrid) -> CGFloat {
        min(size.width, size.height)
            / CGFloat(Double(grid.width) * grid.cellSize)
    }

    private func planCanvas(size: CGSize) -> some View {
        Canvas { ctx, canvasSize in
            guard let grid, snapshot.count == grid.width * grid.height
            else { return }
            let s = scale(for: canvasSize, grid: grid)
            let cellPx = s * CGFloat(grid.cellSize)

            func toPx(_ p: Vec) -> CGPoint {
                CGPoint(x: CGFloat(p.x - grid.origin.x) * s,
                        y: canvasSize.height
                            - CGFloat(p.y - grid.origin.y) * s)
            }

            for y in 0..<grid.height {
                for x in 0..<grid.width {
                    let v = snapshot[y * grid.width + x]
                    guard v != 0 else { continue }
                    let rect = CGRect(
                        x: CGFloat(x) * cellPx,
                        y: canvasSize.height - CGFloat(y + 1) * cellPx,
                        width: cellPx + 0.5, height: cellPx + 0.5)
                    ctx.fill(Path(rect), with: .color(
                        v == 1 ? Color(red: 0.10, green: 0.28, blue: 0.28)
                               : Color(red: 0.85, green: 0.65,
                                       blue: 0.25)))
                }
            }
            if let a = pointA {
                marker(ctx: ctx, at: toPx(a), color: .brandThread)
            }
            if let b = pointB {
                marker(ctx: ctx, at: toPx(b), color: .green)
            }
            if let a = pointA, let b = pointB {
                var line = Path()
                line.move(to: toPx(a))
                line.addLine(to: toPx(b))
                ctx.stroke(line, with: .color(.white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func marker(ctx: GraphicsContext, at p: CGPoint,
                        color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6,
                                        width: 12, height: 12)),
                 with: .color(color))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9,
                                          width: 18, height: 18)),
                   with: .color(color.opacity(0.5)), lineWidth: 2)
    }

    private func place(_ tap: CGPoint, in size: CGSize) {
        guard let grid else { return }
        let s = scale(for: size, grid: grid)
        let wx = grid.origin.x + Double(tap.x / s)
        let wy = grid.origin.y + Double((size.height - tap.y) / s)
        let p = Vec(wx, wy)
        if pointA == nil {
            pointA = p
        } else if pointB == nil {
            pointB = p
            measure()
        } else {
            clear()
            pointA = p
        }
    }

    private func clear() {
        pointA = nil
        pointB = nil
        straight = nil
        walking = nil
        narrowest = nil
        noRoute = false
    }

    private func measure() {
        guard let grid, let a = pointA, let b = pointB else { return }
        straight = dist(a, b)
        grid.refreshClearance(force: true)
        guard let res = plan(grid: grid, start: grid.worldToCell(a),
                             goal: grid.worldToCell(b),
                             params: engine.params) else {
            walking = nil
            narrowest = nil
            noRoute = true
            return
        }
        noRoute = false
        let sm = smooth(grid: grid, cells: res.cells,
                        params: engine.params)
        walking = polylineLength(sm)
        narrowest = corridorProfile(grid: grid, pts: sm)
            .map(\.1).min()
    }
}
