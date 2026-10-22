#if os(iOS)
import SwiftUI

/// Cold-start splash: the app icon's pulse mark draws on in white over black, then the camera zooms through it into the
/// dashboard, which is already rendered underneath. Shown once per process (the owner holds the flag in `@State`).
struct NoopSplashView: View {
    /// Launch arguments that mean a test or screenshot harness is driving the app: the splash would only get in its way.
    /// `--noop-splash` forces it back on for verification.
    static var shouldShowOnLaunch: Bool {
        let args = CommandLine.arguments
        if args.contains("--noop-splash") { return true }
        // No background-launch check here: before the first scene connects, applicationState reads .background even
        // for a normal tap. A background launch (BLE restoration) renders no frames, so the frame-driven clock holds
        // the splash until the app is actually opened.
        if args.contains("--no-splash") || args.contains("--demo-seed") || args.contains("--demo-tab")
            || args.contains("--storage-recovery-qa") || args.contains(where: { $0.hasPrefix("--noop-") }) {
            return false
        }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = SplashClock()

    /// Total length of the animation in seconds of RENDERED time.
    private var duration: Double { reduceMotion ? 0.75 : 2.25 }

    var body: some View {
        // The timeline is driven by rendered frames, not the wall clock. On a cold start the main thread can be
        // blocked for seconds before the first frame; a wall-clock timeline would finish while nothing was on
        // screen. `SplashClock` advances by at most 50 ms per frame, so every frame of the animation is shown.
        TimelineView(.animation) { context in
            let t = clock.advance(to: context.date)
            frame(at: t)
                .onChange(of: t >= duration) { _, done in
                    if done { onFinished() }
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func frame(at t: Double) -> some View {
        let v = values(at: t)
        return ZStack {
            Color.black
            PulseMark()
                .trim(from: 0, to: v.drawn)
                .stroke(.white, style: StrokeStyle(lineWidth: 26, lineCap: .round, lineJoin: .round))
                .shadow(color: .white.opacity(0.55 * v.glow), radius: 18)
                .frame(width: 168, height: 168)
                .scaleEffect(v.scale)
                .opacity(v.markOpacity)
        }
        .opacity(v.cover)
        .allowsHitTesting(v.cover > 0.01)
    }

    private struct Values { var drawn = 0.0, markOpacity = 0.0, scale = 0.92, glow = 0.0, cover = 1.0 }

    /// Same timeline as the original animation calls: mark fades/settles in (0.45s), the stroke draws (0.1s delay,
    /// 1.0s), the glow rises (0.7s delay, 0.7s), then at 1.5s the camera zooms through the mark while the black
    /// falls away, ending at 2.25s.
    private func values(at t: Double) -> Values {
        if reduceMotion {
            return Values(drawn: 1, markOpacity: 1, scale: 1, glow: 0,
                          cover: 1 - Self.ease(.inOut, (t - 0.15) / 0.6))
        }
        var v = Values()
        let appear = Self.ease(.out, t / 0.45)
        v.markOpacity = appear
        v.scale = 0.92 + 0.08 * appear
        v.drawn = Self.ease(.inOut, (t - 0.1) / 1.0)
        v.glow = Self.ease(.inOut, (t - 0.7) / 0.7)
        let exit = t - 1.5
        if exit > 0 {
            v.scale = 1 + 17 * Self.ease(.zoom, exit / 0.7)
            v.markOpacity = 1 - Self.ease(.in, (exit - 0.15) / 0.45)
            v.cover = 1 - Self.ease(.inOut, (exit - 0.15) / 0.55)
        }
        return v
    }

    private enum Curve {
        case inOut, out, `in`, zoom
        var points: (Double, Double, Double, Double) {
            switch self {
            case .inOut: (0.42, 0, 0.58, 1)
            case .out: (0, 0, 0.58, 1)
            case .in: (0.42, 0, 1, 1)
            case .zoom: (0.6, 0, 0.9, 0.4)
            }
        }
    }

    /// Cubic-bezier easing, `x` clamped to 0...1.
    private static func ease(_ curve: Curve, _ x: Double) -> Double {
        let x = min(1, max(0, x))
        let (x1, y1, x2, y2) = curve.points
        func bez(_ a: Double, _ b: Double, _ u: Double) -> Double {
            3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bez(x1, x2, mid) < x { lo = mid } else { hi = mid }
        }
        return bez(y1, y2, (lo + hi) / 2)
    }
}

/// Accumulates rendered animation time, capping each frame's step so a long main-thread stall at launch
/// cannot skip the animation.
final class SplashClock {
    private var last: Date?
    private var elapsed = 0.0

    func advance(to date: Date) -> Double {
        // Body can be evaluated more than once per frame; only a later date moves the clock.
        if let last, date <= last { return elapsed }
        if let last { elapsed += min(date.timeIntervalSince(last), 0.05) }
        last = date
        return elapsed
    }
}

/// The heartbeat squiggle from the app icon, in a 100x100 box.
private struct PulseMark: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 100 * rect.width, y: rect.minY + y / 100 * rect.height)
        }
        var path = Path()
        path.move(to: p(0, 52))
        path.addLine(to: p(14, 52))
        path.addCurve(to: p(34, 20), control1: p(24, 52), control2: p(26, 20))
        path.addCurve(to: p(50, 72), control1: p(46, 20), control2: p(44, 72))
        path.addCurve(to: p(70, 45), control1: p(58, 72), control2: p(62, 45))
        path.addCurve(to: p(82, 52), control1: p(76, 45), control2: p(76, 52))
        path.addLine(to: p(100, 52))
        return path
    }
}
#endif
