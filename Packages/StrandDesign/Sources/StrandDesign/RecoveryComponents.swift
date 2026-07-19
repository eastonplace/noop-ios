import SwiftUI

// MARK: - Recovery Detail (NOOP scope, data-rich tier)
//
// The Recovery detail surface, redrawn in the Sleep/Stress paper dialect for the future
// Recovery-page rebuild. Detail lives in every layer: the 240° arc carries the 34/67
// band boundaries as track ticks and a delta-vs-yesterday chip under the number; each
// driver row pairs a 7-night sparkline with its hatched typical zone and names the zone;
// a weighted split bar shows what the score actually weighs; and the 14-day history
// reads against tinted band zones with a dashed personal average. Fixture-only.

// MARK: - RecoveryArcCard

public struct RecoveryArcCard: View {
    /// 0–100 recovery score; nil = calibrating.
    let score: Double?
    let yesterday: Double?
    let baseline: String
    let yesterdayLabel: String
    let sevenDay: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    /// The arc sweeps 240°, opening downward (gap centred at the bottom).
    private static let sweep: Double = 240 / 360

    public var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Morning recovery")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text(bandWord.uppercased())
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(accent)
            }
            arc
            Text(why)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
            strip
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9).delay(0.1)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var fraction: Double { min(max((score ?? 0) / 100, 0), 1) }
    private var accent: Color { score.map { RecoveryBands.color(for: $0) } ?? StrandPalette.textTertiary }

    private var bandWord: String {
        guard let score else { return "Calibrating" }
        if score >= 67 { return "High" }
        if score >= 34 { return "Medium" }
        return "Low"
    }

    private var why: String {
        guard let score else { return "First nights build your baseline." }
        if score >= 67 { return "Your body is primed. Take the day on." }
        if score >= 34 { return "Recovering — moderate effort suits today." }
        return "Your body is still recovering. Go easy."
    }

    private var deltaText: String? {
        guard let score, let yesterday else { return nil }
        let delta = Int(score.rounded()) - Int(yesterday.rounded())
        guard delta != 0 else { return "even with yesterday" }
        return "\(delta > 0 ? "▲" : "▼") \(abs(delta)) vs yesterday"
    }

    private var deltaColor: Color {
        guard let score, let yesterday else { return StrandPalette.textTertiary }
        if score.rounded() == yesterday.rounded() { return StrandPalette.textTertiary }
        return score > yesterday ? StrandPalette.statusPositive : StrandPalette.metricRose
    }

    private var arc: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height * 1.35)
            let lineWidth: CGFloat = 11
            let radius = side / 2 - lineWidth / 2
            ZStack {
                // Track.
                Circle()
                    .trim(from: 0, to: Self.sweep)
                    .stroke(StrandPalette.surfaceInset, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(150))
                // Fine instrument ticks inside the track — quiet scale texture.
                ForEach(0..<25, id: \.self) { index in
                    let angle = Angle.degrees(150 + 240 * Double(index) / 24)
                    Capsule(style: .continuous)
                        .fill(StrandPalette.hairline)
                        .frame(width: 1, height: 4)
                        .rotationEffect(angle + .degrees(90))
                        .offset(
                            x: cos(angle.radians) * (radius - lineWidth / 2 - 7),
                            y: sin(angle.radians) * (radius - lineWidth / 2 - 7)
                        )
                }
                // Band boundary ticks at 34 and 67 — the scale earns its colour honestly.
                ForEach([34.0, 67.0], id: \.self) { bound in
                    let angle = Angle.degrees(150 + 240 * bound / 100)
                    Capsule(style: .continuous)
                        .fill(StrandPalette.hairlineStrong)
                        .frame(width: 2, height: lineWidth + 6)
                        .rotationEffect(angle + .degrees(90))
                        .offset(
                            x: cos(angle.radians) * radius,
                            y: sin(angle.radians) * radius
                        )
                }
                // Scale end labels.
                scaleLabel("0", at: .degrees(150), radius: radius + 16)
                scaleLabel("100", at: .degrees(30), radius: radius + 16)
                // Value arc, trim-revealed in the band colour.
                Circle()
                    .trim(from: 0, to: Self.sweep * (revealed ? fraction : 0))
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(150))
                // Tip bead — the arc's leading edge, ringed like every peak marker in the system.
                if score != nil, revealed {
                    let angle = Angle.degrees(150 + 240 * fraction)
                    Circle()
                        .fill(accent)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
                        .transition(.opacity)
                }
                VStack(spacing: 4) {
                    Text(score.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(StrandFont.number(40, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    if let deltaText {
                        Text(deltaText)
                            .font(StrandFont.micro.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(deltaColor)
                    }
                }
                .offset(y: 8)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 172)
    }

    private func scaleLabel(_ text: String, at angle: Angle, radius: CGFloat) -> some View {
        Text(text)
            .font(StrandFont.micro)
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
    }

    /// Baseline / Yesterday / 7-day strip — the SleepWindowStrip three-column grammar.
    private var strip: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, (proxy.size.width - 2) / 3)
            HStack(spacing: 0) {
                column("Baseline", value: baseline, alignment: .leading).frame(width: columnWidth)
                divider
                column("Yesterday", value: yesterdayLabel, alignment: .center).frame(width: columnWidth)
                divider
                column("7D avg", value: sevenDay, alignment: .trailing).frame(width: columnWidth)
            }
        }
        .frame(height: 46)
    }

    private var divider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 42)
    }

    private func column(_ label: LocalizedStringKey, value: String, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
        return VStack(alignment: alignment, spacing: 4) {
            Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.number(20))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var accessibilitySummary: String {
        guard let score else { return "Recovery calibrating. First nights build your baseline." }
        var parts = ["Recovery \(Int(score.rounded())) of 100, \(bandWord)"]
        if let deltaText { parts.append(deltaText) }
        parts.append("Baseline \(baseline), yesterday \(yesterdayLabel), seven day average \(sevenDay)")
        return parts.joined(separator: ". ")
    }
}

// MARK: - RecoveryStandingRow

/// Where today sits in the last 30 days: a percentile pip rail plus band-day counts.
public struct RecoveryStandingRow: View {
    /// 0…1 — the share of the last 30 days today beats.
    let percentile: Double
    let highDays: Int
    let mediumDays: Int
    let lowDays: Int

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Better than \(Int((percentile * 100).rounded()))% of your last 30 days")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
            }
            PipBar(
                value: min(max(percentile, 0), 1),
                range: 0...1,
                segments: 30,
                tint: RecoveryBands.color(for: percentile * 100),
                height: 8
            )
            HStack(spacing: 10) {
                bandKey(count: highDays, word: "high", color: StrandPalette.recoveryHigh)
                bandKey(count: mediumDays, word: "medium", color: StrandPalette.recoveryMed)
                bandKey(count: lowDays, word: "low", color: StrandPalette.recoveryLow)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Better than \(Int((percentile * 100).rounded())) percent of the last 30 days. \(highDays) high days, \(mediumDays) medium, \(lowDays) low."
        )
    }

    @ViewBuilder
    private func bandKey(count: Int, word: String, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("\(count)d")
                    .font(StrandFont.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(word)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

// MARK: - RecoveryDriverSplit

public struct RecoveryDriverWeight: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let weight: Double
    public let color: Color
}

/// What the score weighs: one segmented bar, each driver's share, with a compact legend.
public struct RecoveryDriverSplit: View {
    let weights: [RecoveryDriverWeight]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let total = max(weights.map(\.weight).reduce(0, +), 0.0001)
                HStack(spacing: 2) {
                    ForEach(weights) { driver in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(driver.color)
                            .frame(width: max(3, proxy.size.width * driver.weight / total - 2))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule(style: .continuous))
            HStack(spacing: 10) {
                ForEach(weights) { driver in
                    HStack(spacing: 4) {
                        Circle().fill(driver.color).frame(width: 5, height: 5)
                        Text("\(Int((driver.weight * 100).rounded()))%")
                            .font(StrandFont.micro.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(driver.label.uppercased())
                            .font(StrandFont.micro)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Score weights: " + weights.map { "\($0.label) \(Int(($0.weight * 100).rounded())) percent" }.joined(separator: ", ")
        )
    }
}

// MARK: - RecoveryFactorRow

public enum RecoveryFactorTone {
    case positive, warning, neutral

    var color: Color {
        switch self {
        case .positive: StrandPalette.statusPositive
        case .warning: StrandPalette.statusWarning
        case .neutral: StrandPalette.textTertiary
        }
    }
}

/// One recovery driver: a 7-night sparkline, today against the hatched typical zone,
/// and the zone named in plain numbers under the bar. SleepStageComparisonRow grammar.
public struct RecoveryFactorRow: View {
    let label: String
    let value: String
    let delta: String
    let tone: RecoveryFactorTone
    /// Today's position on the row's 0…1 scale.
    let position: Double
    /// The typical zone on the same scale.
    let typical: ClosedRange<Double>
    /// The zone in the metric's own units, e.g. "52–71 ms typical".
    let typicalLabel: String
    /// Last 7 nights, oldest → newest, for the leading sparkline.
    let nights: [Double]
    let accent: Color

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Sparkline(
                    values: nights,
                    gradient: Gradient(colors: [accent.opacity(0.5), accent]),
                    lineWidth: 1.6,
                    showsArea: false,
                    showsHead: false,
                    showsHover: false
                )
                .frame(width: 44, height: 14)
                .accessibilityHidden(true)
                Spacer()
                Text(value)
                    .font(StrandFont.captionNumber)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(delta)
                    .font(StrandFont.footnote)
                    .foregroundStyle(tone.color)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let lo = min(max(typical.lowerBound, 0), 1)
                let hi = min(max(typical.upperBound, lo), 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // Hatched typical zone.
                    DiagonalHatch(spacing: 5)
                        .stroke(accent.opacity(0.55), lineWidth: 1)
                        .frame(width: max(0, width * (hi - lo)))
                        .clipShape(Capsule(style: .continuous))
                        .offset(x: width * lo)
                    // Today's marker.
                    Circle()
                        .fill(accent)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .position(x: width * min(max(position, 0), 1), y: 6)
                }
            }
            .frame(height: 12)
            Text(typicalLabel)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value), \(delta), \(typicalLabel)")
    }
}

// MARK: - RecoveryHistoryStrip

/// 14 days of recovery: band-tinted zone backgrounds, a dashed personal average,
/// band-coloured bars with the staggered reveal, anchor day ringed.
public struct RecoveryHistoryStrip: View {
    let days: [CalendarMetricDay]
    let anchorDate: Date
    let calendar: Calendar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var average: Double {
        let values = days.compactMap(\.value)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let height = proxy.size.height
                let count = max(days.count, 1)
                let slot = proxy.size.width / CGFloat(count)
                let barWidth = max(3, slot * 0.44)
                let yOf: (Double) -> CGFloat = { height - height * CGFloat(min(max($0 / 100, 0), 1)) }

                ZStack(alignment: .topLeading) {
                    // The three band zones, faint behind everything.
                    bandZone(from: 67, to: 100, color: StrandPalette.recoveryHigh, height: height, yOf: yOf)
                    bandZone(from: 34, to: 67, color: StrandPalette.recoveryMed, height: height, yOf: yOf)
                    bandZone(from: 0, to: 34, color: StrandPalette.recoveryLow, height: height, yOf: yOf)

                    // Personal average, dashed, labelled at the leading edge.
                    let avgY = yOf(average)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: avgY))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: avgY))
                    }
                    .stroke(
                        StrandPalette.hairlineStrong.opacity(0.9),
                        style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                    )
                    Text("avg \(Int(average.rounded()))")
                        .font(StrandFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .position(x: 20, y: max(7, avgY - 8))

                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        let score = day.value
                        let barHeight = score.map { max(4, CGFloat($0 / 100) * height) } ?? 4
                        let isAnchor = calendar.isDate(day.date, inSameDayAs: anchorDate)
                        Capsule(style: .continuous)
                            .fill(score.map { RecoveryBands.color(for: $0).opacity(isAnchor ? 1 : 0.72) }
                                ?? StrandPalette.surfaceInset)
                            .frame(width: barWidth, height: revealed ? barHeight : 4)
                            .overlay {
                                if isAnchor {
                                    Capsule(style: .continuous)
                                        .stroke(StrandPalette.textPrimary.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .position(
                                x: slot * CGFloat(index) + slot / 2,
                                y: height - (revealed ? barHeight : 4) / 2
                            )
                            .animation(
                                reduceMotion ? nil : StrandMotion.value.delay(Double(index) * 0.025),
                                value: revealed
                            )
                    }
                }
            }
            .frame(height: 64)
            HStack {
                Text(days.first.map { Self.dateFormatter.string(from: $0.date) } ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(days.last.map { Self.dateFormatter.string(from: $0.date) } ?? "")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func bandZone(
        from lo: Double, to hi: Double, color: Color, height: CGFloat, yOf: (Double) -> CGFloat
    ) -> some View {
        let top = yOf(hi)
        let bottom = yOf(lo)
        return Rectangle()
            .fill(color.opacity(0.05))
            .frame(height: max(0, bottom - top))
            .offset(y: top)
    }

    private var accessibilitySummary: String {
        let scored = days.compactMap(\.value)
        let anchor = TrendCalendar.value(on: anchorDate, in: days, calendar: calendar)
        let anchorRead = anchor.map { "\(Int($0.rounded()))" } ?? "missing"
        return "Fourteen calendar day recovery history, selected day \(anchorRead), \(scored.count) scored days, average \(Int(average.rounded()))."
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}
