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
    /// Tap-anywhere routing confused the first field test ("Planning…"
    /// out of nowhere), so it is opt-in; the scan screen shows the map
    /// as pure feedback and routing starts from Stuff instead.
    var interactive: Bool = false
    /// Remembered things drawn as dots; the located one is highlighted.
    var pins: [(x: Double, y: Double, highlighted: Bool)] = []
    /// The grid rasterized ONCE per gridRevision (~1 Hz). Drawing it
    /// as a single image blit instead of ~80k per-cell path fills per
    /// frame is the difference between a smooth camera and a slideshow
    /// (field test 3).
    @State private var snapshotImage: CGImage?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture { tap in
                if interactive { routeTo(tap, in: geo.size) }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: engine.gridRevision) { _, _ in refresh() }
        .accessibilityLabel(interactive
            ? "Floor plan. Double tap to route to a point."
            : "Floor plan of the scan so far.")
    }

    private func refresh() {
        let g = engine.grid
        let w = g.width
        let h = g.height
        // RGBA pixels, one per cell; the grid's +y up flips to the
        // image's row 0 at top
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let row = (h - 1 - y) * w
            for x in 0..<w {
                let lo = g.lo[y * w + x]
                let i = (row + x) * 4
                if lo >= LO_OCC {
                    pixels[i] = 217; pixels[i + 1] = 166
                    pixels[i + 2] = 64; pixels[i + 3] = 255
                } else if lo <= LO_FREE {
                    pixels[i] = 26; pixels[i + 1] = 71
                    pixels[i + 2] = 71; pixels[i + 3] = 255
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return
        }
        snapshotImage = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
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
        let scale = min(size.width, size.height)
            / CGFloat(Double(g.width) * g.cellSize)

        func toPx(_ p: Vec) -> CGPoint {
            CGPoint(x: CGFloat(p.x - g.origin.x) * scale,
                    y: size.height - CGFloat(p.y - g.origin.y) * scale)
        }

        if let snapshotImage {
            let side = CGFloat(Double(g.width) * g.cellSize) * scale
            ctx.draw(Image(decorative: snapshotImage, scale: 1),
                     in: CGRect(x: 0, y: size.height - side,
                                width: side, height: side))
        }

        if engine.smoothedPath.count >= 2 {
            var path = Path()
            path.move(to: toPx(engine.smoothedPath[0]))
            for p in engine.smoothedPath.dropFirst() {
                path.addLine(to: toPx(p))
            }
            ctx.stroke(path, with: .color(.brandThread), lineWidth: 2)
        }
        if let goal = engine.goal {
            let p = toPx(goal)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4,
                                            width: 8, height: 8)),
                     with: .color(.green))
        }

        for pin in pins {
            let p = toPx(Vec(pin.x, pin.y))
            if pin.highlighted {
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7,
                                           width: 14, height: 14)),
                    with: .color(.green), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5,
                                                width: 7, height: 7)),
                         with: .color(.green))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5,
                                                width: 5, height: 5)),
                         with: .color(.yellow.opacity(0.85)))
            }
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
