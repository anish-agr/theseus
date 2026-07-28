// The Theseus thread — the entire brand is one drawing: a continuous
// thread that ends in a glowing destination dot. Every animation here
// obeys the spec in docs/BRAND.md: smooth cubic easing, no bouncing, no
// spinning, no checkmarks, no shaking. The thread DRAWS itself (trim),
// it never fades in; only the destination dot ever glows.
import SwiftUI

// ---- palette ---------------------------------------------------------------

extension Color {
    /// Deep indigo — the world the thread lives in. #0E1B4D
    static let brandIndigo = Color(red: 14 / 255, green: 27 / 255,
                                   blue: 77 / 255)
    /// A darker floor for full-screen backgrounds so indigo panels
    /// still read as panels on top of it.
    static let brandIndigoDeep = Color(red: 8 / 255, green: 16 / 255,
                                       blue: 48 / 255)
    /// Electric blue — the thread itself. #33A8FF
    static let brandThread = Color(red: 51 / 255, green: 168 / 255,
                                   blue: 255 / 255)
    /// Warm white — the destination. Only this color glows. #FFF6E8
    static let brandDot = Color(red: 255 / 255, green: 246 / 255,
                                blue: 232 / 255)
    /// The destination gone cold — the error state. Never shake,
    /// never red: the dot just loses its warmth.
    static let brandDotCool = Color(red: 130 / 255, green: 170 / 255,
                                    blue: 235 / 255)
}

// ---- the thread ------------------------------------------------------------

/// The serpentine from the logo: three horizontal runs joined by two
/// U-turns, drawn START → DOT so `trim(from: 1-t, to: 1)` reveals it
/// backward from the destination (launch) and `trim(from: 0, to: t)`
/// draws it toward the destination (search/loading). U-turns are cubic
/// Béziers rather than arcs — same look under a round-capped stroke,
/// none of the flipped-coordinate arc ambiguity.
struct ThreadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2
        let oy = rect.midY - s / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        // control-point offset that makes a Bézier U-turn read as a
        // semicircle of radius 0.13: r * 4/3
        let k: CGFloat = 0.173
        var p = Path()
        p.move(to: pt(0.24, 0.20))
        p.addLine(to: pt(0.58, 0.20))
        p.addCurve(to: pt(0.58, 0.46),
                   control1: pt(0.58 + k, 0.20),
                   control2: pt(0.58 + k, 0.46))
        p.addLine(to: pt(0.38, 0.46))
        p.addCurve(to: pt(0.38, 0.72),
                   control1: pt(0.38 - k, 0.46),
                   control2: pt(0.38 - k, 0.72))
        // run all the way INTO the destination dot — the thread and
        // the destination are one thing, never separated by a gap
        p.addLine(to: pt(0.76, 0.72))
        return p
    }

    /// Where the destination dot sits, just past the thread's end.
    static func dotCenter(in rect: CGRect) -> CGPoint {
        let s = min(rect.width, rect.height)
        return CGPoint(x: rect.midX - s / 2 + 0.82 * s,
                       y: rect.midY - s / 2 + 0.72 * s)
    }
}

/// Thread + destination dot, with the visible span of the thread
/// controlled by `from`/`to` (both 0…1 along the path). The dot is
/// always visible — the destination exists before the way there does.
struct ThreadView: View {
    var from: CGFloat = 0
    var to: CGFloat = 1
    var threadOpacity: Double = 1
    var dotScale: CGFloat = 1
    var dotGlow: Double = 0        // 0…1, drives the halo
    var dotColor: Color = .brandDot

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let s = min(geo.size.width, geo.size.height)
            let dot = ThreadShape.dotCenter(in: rect)
            ZStack {
                ThreadShape()
                    .trim(from: from, to: to)
                    .stroke(
                        // royal blue at the origin brightening to the
                        // electric highlight near the destination —
                        // the light lives where you're headed
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.38,
                                           blue: 0.92),
                                     Color.brandThread,
                                     Color(red: 0.52, green: 0.83,
                                           blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing),
                        style: StrokeStyle(lineWidth: s * 0.085,
                                           lineCap: .round,
                                           lineJoin: .round))
                    .opacity(threadOpacity)
                Circle()
                    .fill(dotColor)
                    .frame(width: s * 0.13, height: s * 0.13)
                    .scaleEffect(dotScale)
                    .shadow(color: dotColor.opacity(0.9 * dotGlow),
                            radius: s * 0.10 * dotGlow)
                    .shadow(color: dotColor.opacity(0.5 * dotGlow),
                            radius: s * 0.22 * dotGlow)
                    .position(dot)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The static logo mark: full thread, resting dot.
struct ThreadLogoView: View {
    var body: some View {
        ThreadView(dotGlow: 0.25)
    }
}

// ---- launch ----------------------------------------------------------------

/// Cold-start ritual, ~1.5 s total: only the dot exists, the thread
/// traces itself backward from the dot as if drawn by an invisible pen,
/// the dot gives one soft pulse, everything ends completely still, the
/// overlay hands the screen over.
struct LaunchOverlay: View {
    var onFinished: () -> Void
    @State private var drawn: CGFloat = 0     // 0 = dot only, 1 = full
    @State private var glow: Double = 0
    @State private var pulse: CGFloat = 1

    var body: some View {
        ZStack {
            Color.brandIndigoDeep.ignoresSafeArea()
            ThreadView(from: 1 - drawn, to: 1,
                       dotScale: pulse, dotGlow: glow)
                .frame(width: 190, height: 190)
        }
        .task {
            withAnimation(.easeInOut(duration: 0.85)) { drawn = 1 }
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.easeInOut(duration: 0.28)) {
                glow = 1
                pulse = 1.15
            }
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.easeInOut(duration: 0.32)) {
                glow = 0.25
                pulse = 1
            }
            try? await Task.sleep(for: .seconds(0.45))
            onFinished()
        }
    }
}

// ---- loading ---------------------------------------------------------------

/// The anti-spinner. The thread draws itself toward the destination,
/// fades, and begins again — slow, almost meditative. The dot never
/// leaves. Drop-in replacement anywhere a ProgressView would have spun.
struct ThreadLoadingView: View {
    var size: CGFloat = 56
    @State private var to: CGFloat = 0.001
    @State private var threadOpacity: Double = 1

    var body: some View {
        ThreadView(from: 0, to: to,
                   threadOpacity: threadOpacity, dotGlow: 0.3)
            .frame(width: size, height: size)
            .task {
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 1.7)) { to = 1 }
                    try? await Task.sleep(for: .seconds(1.75))
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeOut(duration: 0.5)) {
                        threadOpacity = 0
                    }
                    try? await Task.sleep(for: .seconds(0.55))
                    to = 0.001
                    threadOpacity = 1
                }
            }
            .accessibilityLabel("Loading")
    }
}

// ---- success ---------------------------------------------------------------

/// The success mark: never a checkmark. The destination dot grows ~15%,
/// emits one warm glow, returns to normal, done.
struct SuccessDot: View {
    var size: CGFloat = 22
    @State private var glow: Double = 0
    @State private var scale: CGFloat = 1

    var body: some View {
        Circle()
            .fill(Color.brandDot)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .shadow(color: Color.brandDot.opacity(0.9 * glow),
                    radius: size * 0.5 * glow)
            .task {
                withAnimation(.easeInOut(duration: 0.3)) {
                    glow = 1
                    scale = 1.15
                }
                try? await Task.sleep(for: .seconds(0.35))
                withAnimation(.easeInOut(duration: 0.4)) {
                    glow = 0.2
                    scale = 1
                }
            }
    }
}

// ---- backgrounds -----------------------------------------------------------

/// The indigo world, applied per-screen so system chrome (tab bar,
/// sheets) keeps its own dark materials — full indigo, but with reason.
struct BrandBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.brandIndigo, Color.brandIndigoDeep],
                    startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }
}

extension View {
    func brandBackground() -> some View {
        modifier(BrandBackground())
    }
}
