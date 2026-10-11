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

    static func color(for bpm: Double, zones: HRZoneStyle.Thresholds = .default) -> Color {
        StrandPalette.sample(stops: stops(zones), at: HRZoneStyle.unit(bpm))
    }

    /// The ramp's anchors sit at the same place in each zone whatever the wearer's boundaries are.
    private static func stops(_ zones: HRZoneStyle.Thresholds) -> [Gradient.Stop] {
        [
            .init(color: rest, location: 0),
            .init(color: rest, location: HRZoneStyle.unit(zones.anchor(58))),
            .init(color: steady, location: HRZoneStyle.unit(zones.anchor(92))),
            .init(color: steady, location: HRZoneStyle.unit(zones.anchor(112))),
            .init(color: push, location: HRZoneStyle.unit(zones.anchor(142))),
            .init(color: push, location: 1),
        ]
    }
}

// MARK: - HRLiveModuleCard

public struct HRLiveModuleCard: View {
    /// The wearer's rest / steady / push boundaries (the profile's, set at the app's root).
    @Environment(\.hrZoneThresholds) private var zones
    /// Trailing ~2 hours of samples, oldest → newest; empty = waiting for signal.
    let samples: [HRTrackPoint]
    /// Resting HR baseline for the dashed rule; nil hides it.
    var restingHR: Double? = nil
    var surfaceStyle: ComponentSurfaceStyle = .flat
    let timeLabel: (TimeInterval) -> String
    var onOpen: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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

    /// The widget eyebrow: a beating heart in the live red, the caps title, and the zone word as a tone pill.
    /// The pill is the Coach "Stale" pill's exact size and its height is part of the row, so this header is
    /// as tall as the Stress one and nothing overhangs it into the air above.
    ///
    /// At an accessibility size the title and the pill cannot share a row ("LIVE H…"), so the pill drops under the
    /// title and the title wraps instead of truncating. Every smaller size is the one-row header exactly as it was.
    @ViewBuilder private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack(spacing: NoopMetrics.space2) {
                    liveHeart
                    Text("Live Heart Rate")
                        .strandOverlineFitted()
                        .lineLimit(3)
                }
                zonePill
            }
        } else {
            HStack(spacing: NoopMetrics.space2) {
                liveHeart
                Text("Live Heart Rate")
                    .strandOverline()
                    .lineLimit(1)
                Spacer(minLength: NoopMetrics.space2)
                zonePill
            }
        }
    }

    /// The live heart: a heart in the live red whose ghost swells and fades at the wearer's cadence (the old dot's
    /// breathing halo, in the shape of the symbol). It holds still under Reduce Motion.
    private var liveHeart: some View {
        EyebrowPulseIcon(systemName: "heart.fill",
                         color: samples.isEmpty ? StrandPalette.textTertiary : HRModuleTint.live,
                         period: breathPeriod,
                         pulses: !samples.isEmpty)
    }

    @ViewBuilder private var zonePill: some View {
        if displayed != nil {
            HRZonePill(word: zoneWord)
                .contentTransition(.opacity)
        } else {
            // Waiting for a first reading: keep the row as tall as it will be, so the pill arriving
            // does not push the module down.
            HRZonePill(word: String(localized: "Steady")).hidden()
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
            HStack(spacing: 0) {
                // The app's string table carries the translations ("ppm" in Spanish).
                Text("bpm")
                    .foregroundStyle(StrandPalette.textSecondary)
                if !heroContext.isEmpty {
                    Text(verbatim: " \(heroContext)")
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .font(StrandFont.micro)
            Spacer(minLength: 0)
        }
        .animation(StrandMotion.fade, value: scrubIndex)
    }

    private var zoneWord: String {
        guard let displayed else { return "" }
        switch zones.zone(for: displayed.bpm) {
        case 0: return String(localized: "Resting")
        case 1: return String(localized: "Steady")
        default: return String(localized: "Pushing")
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
                    .onChangeCompat(of: size.width) { plotWidth = $0 }
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
            // Resting-HR rule, labelled at the leading edge. It stops short of a rail label that sits on its
            // line, so the dashes never run through the number.
            if let restingHR {
                let y = yOf(restingHR)
                let crossesRailLabel = [Self.railLabelY, size.height - Self.railLabelY].contains { abs($0 - y) < 9 }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: crossesRailLabel ? size.width - Self.railRuleClearance : size.width, y: y))
                }
                .stroke(
                    StrandPalette.hairlineStrong.opacity(0.9),
                    style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                )
                let rhrLabel = Text("RHR \(Int(restingHR.rounded()))")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                if typeSize.isAccessibilitySize {
                    // The label is wider than the 44pt it is centred in at an accessibility size, which pushed its
                    // first letters past the card's edge: it starts at the leading edge instead.
                    rhrLabel
                        .fixedSize()
                        .frame(width: size.width, alignment: .leading)
                        .position(x: size.width / 2, y: max(7, y - 8))
                } else {
                    rhrLabel.position(x: 22, y: max(7, y - 8))
                }
            }

            areaPath(rendered, height: size.height)
                .fill(
                    // The Coach trend charts' wash: the domain ink at 14% fading to nothing.
                    LinearGradient(
                        colors: [DomainTint.heart.accent.opacity(0.14), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(revealed ? 1 : 0)
            linePath(rendered)
                .trim(from: 0, to: revealed ? 1 : 0)
                .stroke(zoneGradient, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

            // Rails at the visible extremes, inset so the live head (a bead and its pulse ring, ~11pt out)
            // never touches them. Drawn over the trace with a canvas knock-out, so a line that passes under a
            // label stays legible and reads as passing behind it.
            railLabel(Int(yr.upperBound.rounded()), y: Self.railLabelY, width: size.width)
            railLabel(Int(yr.lowerBound.rounded()), y: size.height - Self.railLabelY, width: size.width)

            // The newest sample, pulsing quietly — this is the LIVE edge.
            if revealed, scrubIndex == nil, let lastPoint = rendered.last, let latest {
                HRLivePulseBead(color: HRModuleTint.color(for: latest.bpm, zones: zones))
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
                    .fill(HRModuleTint.color(for: sample.bpm, zones: zones))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                    .position(x: point.0, y: point.1)
                ChartTooltip(
                    value: "\(Int(sample.bpm.rounded())) bpm",
                    label: timeLabel(sample.t),
                    accent: HRModuleTint.color(for: sample.bpm, zones: zones)
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

    private static let railLabelY: CGFloat = 7
    /// Right edge of a rail label, from the plot's trailing edge: the head bead (4pt radius) plus its pulse ring
    /// (about 11pt at full spread) plus at least 4pt of air.
    private static let railLabelInset: CGFloat = 16
    private static let railLabelWidth: CGFloat = 28
    /// Where a rule that would cross a rail label ends, measured from the trailing edge.
    private static let railRuleClearance: CGFloat = 40

    private func railLabel(_ value: Int, y: CGFloat, width: CGFloat) -> some View {
        Text("\(value)")
            .font(StrandFont.micro).monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            // The knock-out grows outward from the digits (3pt across, 1pt up and down), so they don't move.
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(StrandPalette.appCanvas.opacity(0.88))
                    .padding(.horizontal, -3)
                    .padding(.vertical, -1)
            }
            .frame(width: Self.railLabelWidth, alignment: .trailing)
            .position(x: width - Self.railLabelInset - Self.railLabelWidth / 2, y: y)
    }

    /// Vertical zone ramp projected onto the visible range — colour tells effort truthfully.
    private var zoneGradient: LinearGradient {
        let lo = yRange.lowerBound
        let span = yRange.upperBound - lo
        let stops = stride(from: 0.0, through: 1.0, by: 0.2).map { position in
            Gradient.Stop(color: HRModuleTint.color(for: lo + position * span, zones: zones), location: position)
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
            if typeSize.isAccessibilitySize {
                // Three keys and the range chip do not fit one row at an accessibility size (each broke to a letter per
                // line), so they stack. Every smaller size is the one row it was.
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    footKey(label: "low", value: "\(low)")
                    footKey(label: "avg", value: "\(average)")
                    footKey(label: "peak", value: "\(peak)")
                    rangeChip
                }
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    footKey(label: "low", value: "\(low)")
                    footKey(label: "avg", value: "\(average)")
                    footKey(label: "peak", value: "\(peak)")
                    Spacer(minLength: 0)
                    rangeChip
                }
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

    /// "2H ›" as the shared compact chip.
    private var rangeChip: some View {
        WidgetChip("2H")
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

/// A zone word ("Resting", "Steady", "Pushing") on the shared state-pill chrome (the Coach "Stale" pill's
/// exact metrics), washed and outlined in the live red with the pill's white type.
private struct HRZonePill: View {
    let word: String

    var body: some View {
        Text(verbatim: word)
            .statePillLabel()
            .statePillChrome(tint: HRModuleTint.live)
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

// Keep stateful public initializers in the declaring file for Swift 6.4 code generation.
public extension HRLiveModuleCard {
    init(
        _publicAPI: Void = (),
        samples: [HRTrackPoint],
        restingHR: Double? = nil,
        surfaceStyle: ComponentSurfaceStyle = .flat,
        timeLabel: @escaping (TimeInterval) -> String,
        onOpen: @escaping () -> Void = {}
    ) {
        self.samples = samples
        self.restingHR = restingHR
        self.surfaceStyle = surfaceStyle
        self.timeLabel = timeLabel
        self.onOpen = onOpen
    }
}
