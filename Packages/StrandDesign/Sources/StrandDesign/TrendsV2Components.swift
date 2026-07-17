import SwiftUI

// MARK: - Trends V2 (NOOP scope, data-rich tier)
//
// The Trends tab, re-spoken in the Sleep/Stress paper dialect. Detail in every layer:
// the hero panel shades your typical zone behind the line, rules the dashed baseline,
// and scrubs under a finger with the shared crosshair/tooltip grammar; a month reads as
// a heat grid with the best day ringed; delta rows ride the production Sparkline; and
// the weekday read carries its own average rule and names the strongest day. Replaces
// the older lab Trends grammar (ordinal 4) rather than editing it, so both generations
// stay reviewable side by side. Fixture-only.

// MARK: - Ranges

public enum TrendRange: String, CaseIterable, Identifiable {
    case week = "W"
    case month = "M"
    case quarter = "3M"
    case half = "6M"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .half: 180
        }
    }

    public var startLabel: String {
        switch self {
        case .week: "7d ago"
        case .month: "30d ago"
        case .quarter: "3mo ago"
        case .half: "6mo ago"
        }
    }

    public func dayLabel(_ index: Int, of count: Int) -> String {
        let back = count - 1 - index
        if back == 0 { return "Today" }
        if back == 1 { return "Yesterday" }
        return "\(back)d ago"
    }
}

// MARK: - TrendPanelChart

public struct TrendPanelChart: View {
    let values: [Double]
    /// The long-run baseline the dashed rule sits on (e.g. the prior period's mean).
    let baseline: Double
    /// Your typical zone, shaded behind the line so deviation reads instantly.
    let typical: ClosedRange<Double>
    let tint: Color
    let unit: String
    var valueFormat: (Double) -> String = { "\(Int($0.rounded()))" }
    let range: TrendRange

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// Index under the finger while scrubbing, nil when idle.
    @State private var scrubIndex: Int? = nil
    @State private var plotWidth: CGFloat = 1

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            plot.frame(height: 150)
            axis
            hint
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.85).delay(0.1)) {
                revealed = true
            }
        }
    }

    private var unitSuffix: String {
        if unit.isEmpty { return "" }
        return unit == "%" ? "%" : " \(unit)"
    }

    private var last: Double { values.last ?? 0 }
    private var delta: Double { last - baseline }

    private var deltaText: String {
        let arrow = delta >= 0 ? "▲" : "▼"
        return "\(arrow) \(valueFormat(abs(delta))) vs baseline"
    }

    private var deltaColor: Color {
        abs(delta) < 0.001 ? StrandPalette.textTertiary
            : (delta >= 0 ? StrandPalette.statusPositive : StrandPalette.metricRose)
    }

    private var header: some View {
        HStack {
            if let scrubIndex, values.indices.contains(scrubIndex) {
                Text("\(valueFormat(values[scrubIndex]))\(unitSuffix)")
                    .font(StrandFont.captionNumber)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(range.dayLabel(scrubIndex, of: values.count))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("\(valueFormat(last))\(unitSuffix)")
                    .font(StrandFont.captionNumber)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("latest")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Text(deltaText)
                .font(StrandFont.captionNumber)
                .foregroundStyle(deltaColor)
        }
        .animation(StrandMotion.fade, value: scrubIndex)
    }

    private var yRange: ClosedRange<Double> {
        let all = values + [baseline, typical.lowerBound, typical.upperBound]
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return 0...1 }
        let pad = (hi - lo) * 0.16
        return (lo - pad)...(hi + pad)
    }

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            plotLayers(size: size)
                .contentShape(Rectangle())
                .gesture(scrubGesture)
                .onAppear { plotWidth = size.width }
                .onChange(of: size.width) { width in plotWidth = width }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func plotLayers(size: CGSize) -> some View {
        let yr = yRange
        let ySpan = max(yr.upperBound - yr.lowerBound, 0.0001)
        let count = max(values.count, 1)
        let xOf: (Int) -> CGFloat = { count <= 1 ? size.width / 2 : size.width * CGFloat($0) / CGFloat(count - 1) }
        let yOf: (Double) -> CGFloat = { size.height - size.height * CGFloat(($0 - yr.lowerBound) / ySpan) }
        let rendered = values.enumerated().map { (xOf($0.offset), yOf($0.element)) }

        ZStack {
            // Typical zone, shaded behind everything with a quiet name at the top edge.
            let zoneTop = yOf(typical.upperBound)
            let zoneBottom = yOf(typical.lowerBound)
            Rectangle()
                .fill(tint.opacity(0.06))
                .frame(height: max(0, zoneBottom - zoneTop))
                .position(x: size.width / 2, y: (zoneTop + zoneBottom) / 2)
            Text("typical")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.8))
                .position(x: size.width - 22, y: max(8, zoneTop + 9))

            // Baseline rule, labelled at the leading edge (never collides with the bead).
            let baselineY = yOf(baseline)
            Path { path in
                path.move(to: CGPoint(x: 0, y: baselineY))
                path.addLine(to: CGPoint(x: size.width, y: baselineY))
            }
            .stroke(
                StrandPalette.hairlineStrong.opacity(0.9),
                style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
            )
            Text(valueFormat(baseline))
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .position(x: 12, y: max(8, baselineY - 8))

            if rendered.count >= 2 {
                areaPath(rendered, height: size.height)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.16), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(revealed ? 1 : 0)
                linePath(rendered)
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(
                        LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
            }

            if revealed, scrubIndex == nil, let lastPoint = rendered.last {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                    .position(x: lastPoint.0, y: lastPoint.1)
                    .transition(.opacity)
            }

            // Scrub crosshair + dot + tooltip — the shared readout grammar.
            if let scrubIndex, rendered.indices.contains(scrubIndex) {
                let point = rendered[scrubIndex]
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: point.0, y: size.height / 2)
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                    .position(x: point.0, y: point.1)
                ChartTooltip(
                    value: "\(valueFormat(values[scrubIndex]))\(unitSuffix)",
                    label: range.dayLabel(scrubIndex, of: values.count),
                    accent: tint
                )
                .position(
                    ChartTooltipPlacement.position(
                        anchor: CGPoint(x: point.0, y: point.1),
                        tooltipSize: CGSize(width: 104, height: 40),
                        in: size
                    )
                )
            }
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard plotWidth > 0, values.count > 1 else { return }
                let fraction = min(max(Double(drag.location.x / plotWidth), 0), 1)
                let index = Int((fraction * Double(values.count - 1)).rounded())
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

    private var axis: some View {
        HStack {
            Text(range.startLabel)
            Spacer()
            Text("Today")
        }
        .font(StrandFont.micro)
        .foregroundStyle(StrandPalette.textTertiary)
        .accessibilityHidden(true)
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .font(StrandFont.micro.weight(.semibold))
            Text("Touch and drag to read any day")
            Spacer()
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
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

    private var accessibilitySummary: String {
        "Trend, latest \(valueFormat(last))\(unitSuffix), baseline \(valueFormat(baseline)), typical \(valueFormat(typical.lowerBound)) to \(valueFormat(typical.upperBound)), \(values.count) days shown."
    }
}

// MARK: - TrendMonthHeat

/// The last 35 days as a heat grid, Monday columns, best day ringed. Colour carries
/// intensity; the ring and the caption carry meaning without colour (a11y rule).
public struct TrendMonthHeat: View {
    /// 35 values, oldest first, on the metric's own scale.
    let values: [Double]
    let tint: Color
    var valueFormat: (Double) -> String = { "\(Int($0.rounded()))" }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private static let labels = ["M", "T", "W", "T", "F", "S", "S"]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(Self.labels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            grid
            if let best = values.max(), let index = values.firstIndex(of: best) {
                Text("Best \(valueFormat(best)) · \(values.count - 1 - index) days ago")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var grid: some View {
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, 0.0001)
        let bestIndex = values.firstIndex(of: hi)

        return VStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = row * 7 + column
                        let value = values.indices.contains(index) ? values[index] : nil
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(value.map { tint.opacity(0.12 + 0.78 * ($0 - lo) / span) } ?? StrandPalette.surfaceInset)
                            .frame(height: 22)
                            .overlay {
                                if index == bestIndex {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(StrandPalette.textPrimary.opacity(0.6), lineWidth: 1.2)
                                }
                            }
                            .opacity(revealed ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : StrandMotion.fade.delay(Double(index) * 0.008),
                                value: revealed
                            )
                    }
                }
            }
        }
    }

    private var accessibilitySummary: String {
        guard let best = values.max() else { return "No month data yet." }
        let average = values.reduce(0, +) / Double(max(values.count, 1))
        return "Last 35 days, average \(valueFormat(average)), best \(valueFormat(best))."
    }
}

// MARK: - TrendDeltaRow

/// One metric's compact trend read: label, production Sparkline, latest value, delta chip.
public struct TrendDeltaRow: View {
    let label: String
    let subtitle: String
    let values: [Double]
    let latest: String
    let delta: String
    let positive: Bool
    let tint: Color

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Sparkline(
                values: values,
                gradient: Gradient(colors: [tint.opacity(0.55), tint]),
                lineWidth: 1.8,
                showsArea: false,
                showsHead: false,
                showsHover: false
            )
            .frame(width: 64, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 2) {
                Text(latest)
                    .font(StrandFont.number(17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(delta)
                    .font(StrandFont.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(positive ? StrandPalette.statusPositive : StrandPalette.metricRose)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(latest), \(delta)")
    }
}

// MARK: - TrendWeekdayBars

public struct TrendWeekdayBars: View {
    /// Seven averages, Monday-first, on the metric's own scale.
    let values: [Double]
    let tint: Color
    var valueFormat: (Double) -> String = { "\(Int($0.rounded()))" }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private static let labels = ["M", "T", "W", "T", "F", "S", "S"]

    public var body: some View {
        GeometryReader { proxy in
            let count = max(values.count, 1)
            let slot = proxy.size.width / CGFloat(count)
            let barWidth = max(6, slot * 0.42)
            let top = values.max() ?? 1
            let bottom = values.min() ?? 0
            let span = max(top - bottom, 0.0001)
            let average = values.reduce(0, +) / Double(count)
            let best = values.firstIndex(of: top)
            let plotHeight = proxy.size.height - 30
            let heightOf: (Double) -> CGFloat = { value in
                max(6, CGFloat(0.25 + 0.75 * (value - bottom) / span) * plotHeight)
            }

            ZStack(alignment: .topLeading) {
                // Average rule across the bars.
                let avgY = 12 + plotHeight - heightOf(average)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: avgY))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: avgY))
                }
                .stroke(
                    StrandPalette.hairlineStrong.opacity(0.9),
                    style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                )
                Text("avg \(valueFormat(average))")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .position(x: 24, y: max(7, avgY - 8))

                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    let height = heightOf(value)
                    let x = slot * CGFloat(index) + slot / 2
                    if index == best {
                        Text(valueFormat(value))
                            .font(StrandFont.micro.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                            .position(x: x, y: 12 + plotHeight - height - 8)
                    }
                    Capsule(style: .continuous)
                        .fill(tint.opacity(index == best ? 1 : 0.5))
                        .frame(width: barWidth, height: revealed ? height : 6)
                        .position(x: x, y: 12 + plotHeight - (revealed ? height : 6) / 2)
                        .animation(
                            reduceMotion ? nil : StrandMotion.value.delay(Double(index) * 0.03),
                            value: revealed
                        )
                    Text(Self.labels[index % 7])
                        .font(StrandFont.micro)
                        .foregroundStyle(index == best ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .position(x: x, y: 12 + plotHeight + 10)
                }
            }
        }
        .frame(height: 104)
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let top = values.max(), let index = values.firstIndex(of: top) else { return "No weekday data." }
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return "By weekday, strongest \(names[index % 7]) at \(valueFormat(top))."
    }
}
