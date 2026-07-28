// Top-down live minimap: the occupancy grid, the current route, your
// pose and the destination. Tap anywhere walkable to route there.
//
// The grid mutates continuously; rather than redrawing per frame the
// snapshot refreshes on the engine's gridRevision counter (~1 Hz), which
// is plenty for a 280x280 map and keeps the AR view at full rate.
import NavCore
import SwiftUI

struct MinimapView: View {
    @EnvironmentObject var engine: NavEngine
    @State private var snapshot: [UInt8] = []
    @State private var snapshotWidth = 0
    @State private var snapshotHeight = 0

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture { tap in
                routeTo(tap, in: geo.size)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: engine.gridRevision) { _, _ in refresh() }
        .accessibilityLabel("Floor plan. Double tap to route to a point.")
    }

    private func refresh() {
        let g = engine.grid
        var snap = [UInt8](repeating: 0, count: g.width * g.height)
        for i in 0..<g.lo.count {
            if g.lo[i] >= LO_OCC {
                snap[i] = 2
            } else if g.lo[i] <= LO_FREE {
                snap[i] = 1
            }
        }
        snapshot = snap
        snapshotWidth = g.width
        snapshotHeight = g.height
    }

    private func routeTo(_ point: CGPoint, in size: CGSize) {
        let g = engine.grid
        let scale = Double(min(size.width, size.height))
            / (Double(g.width) * g.cellSize)
        let wx = g.origin.x + Double(point.x) / scale
        let wy = g.origin.y + (Double(size.height) - Double(point.y)) / scale
        engine.startGuidance(to: Vec(wx, wy), name: "that spot")
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let g = engine.grid
        guard snapshot.count == snapshotWidth * snapshotHeight,
              snapshotWidth == g.width else { return }
        let scale = min(size.width, size.height)
            / CGFloat(Double(g.width) * g.cellSize)
        let cellPx = scale * CGFloat(g.cellSize)

        func toPx(_ p: Vec) -> CGPoint {
            CGPoint(x: CGFloat(p.x - g.origin.x) * scale,
                    y: size.height - CGFloat(p.y - g.origin.y) * scale)
        }

        for y in 0..<snapshotHeight {
            for x in 0..<snapshotWidth {
                let s = snapshot[y * snapshotWidth + x]
                guard s != 0 else { continue }
                let rect = CGRect(x: CGFloat(x) * cellPx,
                                  y: size.height - CGFloat(y + 1) * cellPx,
                                  width: cellPx + 0.5,
                                  height: cellPx + 0.5)
                ctx.fill(Path(rect), with: .color(
                    s == 1 ? Color(red: 0.10, green: 0.28, blue: 0.28)
                           : Color(red: 0.85, green: 0.65, blue: 0.25)))
            }
        }

        if engine.smoothedPath.count >= 2 {
            var path = Path()
            path.move(to: toPx(engine.smoothedPath[0]))
            for p in engine.smoothedPath.dropFirst() {
                path.addLine(to: toPx(p))
            }
            ctx.stroke(path, with: .color(.cyan), lineWidth: 2)
        }
        if let goal = engine.goal {
            let p = toPx(goal)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.green))
        }

        // you: a triangle pointing along your heading
        let me = toPx(Vec(engine.pose.x, engine.pose.y))
        let h = engine.pose.heading
        var tri = Path()
        let r: CGFloat = 7
        tri.move(to: CGPoint(x: me.x + r * CGFloat(cos(h)),
                             y: me.y - r * CGFloat(sin(h))))
        tri.addLine(to: CGPoint(x: me.x + r * CGFloat(cos(h + 2.5)),
                                y: me.y - r * CGFloat(sin(h + 2.5))))
        tri.addLine(to: CGPoint(x: me.x + r * CGFloat(cos(h - 2.5)),
                                y: me.y - r * CGFloat(sin(h - 2.5))))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(.white))
    }
}
