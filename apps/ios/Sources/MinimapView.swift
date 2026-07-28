// Top-down live minimap: the occupancy grid, the smoothed route, the
// agent pose and goal — the diagnostic overlay from the original spec.
// Tap anywhere walkable to set the guidance goal.
import NavCore
import SwiftUI

struct MinimapView: View {
    @EnvironmentObject var engine: NavEngine
    // redraw throttle: the grid mutates continuously; refreshing the
    // snapshot ~3x/s is plenty for a 240x240 map
    @State private var snapshot: [UInt8] = []
    private let timer = Timer.publish(every: 0.35, on: .main,
                                      in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture { tap in
                let g = engine.grid
                let scale = Double(min(geo.size.width, geo.size.height))
                    / (Double(g.width) * g.cellSize)
                let wx = g.origin.x + Double(tap.x) / scale
                let wy = g.origin.y
                    + (Double(geo.size.height) - Double(tap.y)) / scale
                engine.setGoal(Vec(wx, wy))
            }
        }
        .onReceive(timer) { _ in
            refresh()
        }
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
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let g = engine.grid
        guard snapshot.count == g.width * g.height else { return }
        let scale = min(size.width, size.height)
            / CGFloat(Double(g.width) * g.cellSize)
        let cellPx = scale * CGFloat(g.cellSize)

        func toPx(_ p: Vec) -> CGPoint {
            CGPoint(x: CGFloat(p.x - g.origin.x) * scale,
                    y: size.height - CGFloat(p.y - g.origin.y) * scale)
        }

        for y in 0..<g.height {
            for x in 0..<g.width {
                let s = snapshot[y * g.width + x]
                guard s != 0 else { continue }
                let rect = CGRect(
                    x: CGFloat(x) * cellPx,
                    y: size.height - CGFloat(y + 1) * cellPx,
                    width: cellPx + 0.5, height: cellPx + 0.5)
                ctx.fill(Path(rect),
                         with: .color(s == 1
                                      ? Color(red: 0.1, green: 0.25,
                                              blue: 0.25)
                                      : Color(red: 0.85, green: 0.65,
                                              blue: 0.25)))
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
        if let agent = engine.agentPos {
            let p = toPx(agent)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.orange))
        }
        // the user: triangle pointing along heading
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
