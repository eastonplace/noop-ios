import SwiftUI

// MARK: - HR Module (NOOP scope, data-rich tier)
//
// The Today-screen "Live Heart Rate" module rebuilt for micro-detail — the pre-tap card,
// a separate component from the Deep Timeline chart it opens. Same information contract
// as production (live dot + overline, big BPM, trace with 40/120 rails), every layer
// upgraded in the paper dialect:
//
//   · the live dot breathes at the wearer's cadence — faster when the rate runs high
//   · the BPM badge ticks with a numericText transition and tints by zone
//   · the trace rides the HR zone ramp vertically, with a dashed resting-HR rule,
//     quiet bpm rails, and a pulsing bead on the newest sample
//   · touch-and-drag scrubs the trace: crosshair + tooltip, haptic per sample step,
//     and the header morphs into the scrubbed reading
//   · a Low / Avg / Peak micro strip and the chevron affordance close the card
//   · waiting state stays honest: dimmed flat rail, no fabricated numbers
//
// Fixture-only: presets cover Resting / Workout / Waiting.

private enum HRModuleTint {
    static let rest = StrandPalette.liveRed.opacity(0.58)
    static let steady = StrandPalette.liveRed
    static let push = StrandPalette.destructive
    static let live = StrandPalette.liveRed

    static func color(for bpm: Double) -> Color {
        StrandPalette.sample(stops: stops, at: HRZoneStyle.unit(bpm))
    }

    private static let stops: [Gradient.Stop] = [
        .init(color: rest, location: 0),
        .init(color: rest, location: HRZoneStyle.unit(58)),
        .init(color: steady, location: HRZoneStyle.unit(92)),
        .init(color: steady, location: HRZoneStyle.unit(112)),
        .init(color: push, location: HRZoneStyle.unit(142)),
        .init(color: push, location: 1),
    ]
}

// MARK: - HRLiveModuleCard

public struct HRLiveModuleCard: View {
    /// Trailing ~2 hours of samples, oldest → newest; empty = waiting for signal.
    let samples: [HRTrackPoint]
    /// Resting HR baseline for the dashed rule; nil hides it.
    var restingHR: Double? = nil
    var surfaceStyle: ComponentSurfaceStyle = .flat
    let timeLabel: (TimeInterval) -> String
    var onOpen: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var scrubIndex: Int? = nil
    @State private var plotWidth: CGFloat = 1

    public var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                header
                heroRow
                trace
                footerStrip
            }
            .padding(surfaceStyle == .card ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardSurface)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(StressModulePressStyle())
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.05)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens the Deep Timeline")
    }

    // MARK: Derived

    private var latest: HRTrackPoint? { samples.last }

    private var scrubSample: HRTrackPoint? {
        guard let scrubIndex, samples.indices.contains(scrubIndex) else { return nil }
        return samples[scrubIndex]
    }

    private var displayed: HRTrackPoint? { scrubSample ?? latest }
    private var accent: Color { displayed.map { HRModuleTint.color(for: $0.bpm) } ?? StrandPalette.textTertiary }

    /// The dot breathes faster the harder the heart works (0.6 s at push, 2.4 s at rest).
    private var breathPeriod: Double {
        guard let latest else { return 2.6 }
        let unit = HRZoneStyle.unit(latest.bpm)
        return 2.4 - 1.8 * unit
    }

    // MARK: Chrome

    @ViewBuilder private var cardSurface: some View {
        if surfaceStyle == .card {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
        } else {
            Color.clear
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HRLiveBreathingDot(color: samples.isEmpty ? StrandPalette.textTertiary : HRModuleTint.live,
                               period: breathPeriod,
                               active: !samples.isEmpty)
            Text("Live Heart Rate")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            if displayed != nil {
                Text(zoneWord.uppercased())
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(accent)
                    .contentTransition(.opacity)
            }
        }
    }

    /// The number is the hero — production-sized, zone word beside it, live context under it.
    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(displayed.map { "\(Int($0.bpm.rounded()))" } ?? "—")
                .font(StrandFont.number(38, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(displayed == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .contentTransition(.numericText())
            Text("BPM")
                .font(StrandFont.micro.weight(.bold))
                .foregroundStyle(StrandPalette.textTertiary)
            Text(heroContext)
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.leading, 3)
            Spacer(minLength: 0)
        }
        .animation(StrandMotion.fade, value: scrubIndex)
    }

    private var zoneWord: String {
        guard let displayed else { return "" }
        switch HRZoneStyle.zone(for: displayed.bpm) {
        case 0: return "Resting"
        case 1: return "Steady"
        default: return "Pushing"
        }
    }

    private var heroContext: String {
        if let sample = scrubSample { return "· \(timeLabel(sample.t))" }
        return samples.isEmpty ? "" : "· latest"
    }

    // MARK: Trace

    private static let traceHeight: CGFloat = 54

    private var yRange: ClosedRange<Double> {
        let values = samples.map(\.bpm) + [restingHR ?? 60]
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 40...120 }
        let pad = (hi - lo) * 0.18
        return max(35, lo - pad)...(hi + pad)
    }

    @ViewBuilder
    private var trace: some View {
        if samples.count >= 2 {
            GeometryReader { proxy in
                let size = proxy.size
                traceLayers(size: size)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)
                    .onAppear { plotWidth = size.width }
                    .onChange(of: size.width) { width in plotWidth = width }
            }
            .frame(height: Self.traceHeight)
        } else {
            // Waiting state: a dimmed flat rail, never a fabricated trace.
            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(StrandPalette.hairlineStrong)
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Self.traceHeight / 2 - 4)
                Text("Waiting for live signal — keep the strap nearby.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func traceLayers(size: CGSize) -> some View {
        let yr = yRange
        let ySpan = max(yr.upperBound - yr.lowerBound, 0.0001)
        let count = samples.count
        let xOf: (Int) -> CGFloat = { size.width * CGFloat($0) / CGFloat(max(count - 1, 1)) }
        let yOf: (Double) -> CGFloat = { size.height - size.height * CGFloat(($0 - yr.lowerBound) / ySpan) }
        let rendered = samples.enumerated().map { (xOf($0.offset), yOf($0.element.bpm)) }

        ZStack {
            // Resting-HR rule, labelled at the leading edge.
            if let restingHR {
                let y = yOf(restingHR)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(
                    StrandPalette.hairlineStrong.opacity(0.9),
                    style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                )
                Text("RHR \(Int(restingHR.rounded()))")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .position(x: 22, y: max(7, y - 8))
            }

            // Rails at the visible extremes.
            Text("\(Int(yr.upperBound.rounded()))")
                .font(StrandFont.micro).monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .position(x: size.width - 10, y: 7)
            Text("\(Int(yr.lowerBound.rounded()))")
                .font(StrandFont.micro).monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .position(x: size.width - 10, y: size.height - 7)

            areaPath(rendered, height: size.height)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.14), accent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(revealed ? 1 : 0)
            linePath(rendered)
                .trim(from: 0, to: revealed ? 1 : 0)
                .stroke(zoneGradient, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

            // The newest sample, pulsing quietly — this is the LIVE edge.
            if revealed, scrubIndex == nil, let lastPoint = rendered.last, let latest {
                HRLivePulseBead(color: HRModuleTint.color(for: latest.bpm))
                    .position(x: lastPoint.0, y: lastPoint.1)
            }

            // Scrub crosshair + dot + tooltip.
            if let scrubIndex, rendered.indices.contains(scrubIndex), let sample = scrubSample {
                let point = rendered[scrubIndex]
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: point.0, y: size.height / 2)
                Circle()
                    .fill(HRModuleTint.color(for: sample.bpm))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                    .position(x: point.0, y: point.1)
                ChartTooltip(
                    value: "\(Int(sample.bpm.rounded())) bpm",
                    label: timeLabel(sample.t),
                    accent: HRModuleTint.color(for: sample.bpm)
                )
                .position(
                    ChartTooltipPlacement.position(
                        anchor: CGPoint(x: point.0, y: point.1),
                        tooltipSize: CGSize(width: 100, height: 40),
                        in: size
                    )
                )
            }
        }
    }

    /// Vertical zone ramp projected onto the visible range — colour tells effort truthfully.
    private var zoneGradient: LinearGradient {
        let lo = yRange.lowerBound
        let span = yRange.upperBound - lo
        let stops = stride(from: 0.0, through: 1.0, by: 0.2).map { position in
            Gradient.Stop(color: HRModuleTint.color(for: lo + position * span), location: position)
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .bottom, endPoint: .top)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard plotWidth > 0, samples.count > 1 else { return }
                let fraction = min(max(Double(drag.location.x / plotWidth), 0), 1)
                let index = Int((fraction * Double(samples.count - 1)).rounded())
                if index != scrubIndex {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrubIndex = index }
                    StrandHaptic.selection.play()
                }
            }
            .onEnded { _ in
                withAnimation(StrandMotion.interactive) { scrubIndex = nil }
            }
    }

    private func linePath(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = (previous.0 + current.0) / 2
            path.addCurve(
                to: CGPoint(x: current.0, y: current.1),
                control1: CGPoint(x: midpoint, y: previous.1),
                control2: CGPoint(x: midpoint, y: current.1)
            )
        }
        return path
    }

    private func areaPath(_ points: [(CGFloat, CGFloat)], height: CGFloat) -> Path {
        var path = linePath(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    // MARK: Footer

    @ViewBuilder
    private var footerStrip: some View {
        if !samples.isEmpty {
            let values = samples.map(\.bpm)
            let low = Int((values.min() ?? 0).rounded())
            let average = Int((values.reduce(0, +) / Double(values.count)).rounded())
            let peak = Int((values.max() ?? 0).rounded())
            HStack(spacing: 10) {
                footKey(label: "low", value: "\(low)")
                footKey(label: "avg", value: "\(average)")
                footKey(label: "peak", value: "\(peak)")
                Spacer(minLength: 0)
                Text("2H")
                    .font(StrandFont.micro.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            HStack {
                Text("The trace starts with the first reading.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func footKey(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(StrandFont.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(label.uppercased())
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var accessibilitySummary: String {
        guard let latest else { return "Live heart rate, waiting for signal." }
        let values = samples.map(\.bpm)
        let low = Int((values.min() ?? 0).rounded())
        let peak = Int((values.max() ?? 0).rounded())
        return "Live heart rate \(Int(latest.bpm.rounded())) beats per minute. Last two hours: low \(low), peak \(peak)."
    }
}

/// The live dot: breathing halo whose period follows the heart rate itself.
private struct HRLiveBreathingDot: View {
    let color: Color
    let period: Double
    let active: Bool

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if active && !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.3), lineWidth: 4)
                        .scaleEffect(breathing ? 1.7 : 0.9)
                        .opacity(breathing ? 0 : 0.8)
                }
            }
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeOut(duration: max(period, 0.5)).repeatForever(autoreverses: false)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The trailing live sample: a ringed bead with a soft repeating pulse.
private struct HRLivePulseBead: View {
    let color: Color

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
            .overlay {
                if !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.35), lineWidth: 3)
                        .scaleEffect(pulsing ? 2.4 : 1)
                        .opacity(pulsing ? 0 : 0.9)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}
