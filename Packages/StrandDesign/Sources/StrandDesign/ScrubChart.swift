import SwiftUI

// MARK: - Scrub chart
//
// A dated series in the Coach/Trends chart recipe, for screens that own their readout (a hero value above, a caption
// below): a tinted line over a wash that fades from 14% to clear, or tinted bars, at most four evenly spaced date
// labels, and touch-and-hold-then-drag to read any day. The chart draws nothing but the plot; it reports which point is
// under the finger through `selection` and the caller turns that into words. A screen that already has a baseline, a
// typical band and a delta pill uses `TrendsHeroChart` instead.

/// One reading on a `ScrubChart`.
public struct ScrubChartPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// The plot geometry of a `ScrubChart`, kept apart from the view so it can be tested without drawing.
enum ScrubChartGeometry {
    /// Where a date falls along the domain, 0 at its start and 1 at its end.
    static func unitPosition(of date: Date, in domain: ClosedRange<Date>) -> Double {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return 0.5 }
        return min(max(date.timeIntervalSince(domain.lowerBound) / span, 0), 1)
    }

    /// The index of the point nearest the finger, or nil when there are none. `xs` are the points' x positions.
    static func nearestIndex(toX x: CGFloat, in xs: [CGFloat]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        var distance = abs(xs[0] - x)
        for index in xs.indices.dropFirst() {
            let candidate = abs(xs[index] - x)
            if candidate < distance {
                best = index
                distance = candidate
            }
        }
        return best
    }

    /// How many date labels fit under a plot: four from regular text up to the largest standard size, two beyond it.
    static func labelCount(isAccessibilitySize: Bool) -> Int { isAccessibilitySize ? 2 : 4 }

    /// The dates the labels sit under, evenly spaced across the domain, first to last.
    static func labelDates(in domain: ClosedRange<Date>, count: Int) -> [Date] {
        guard count > 1 else { return [domain.lowerBound] }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return (0..<count).map { domain.lowerBound.addingTimeInterval(span * Double($0) / Double(count - 1)) }
    }

    /// Bars take 62% of the room between neighbours, between 3 and 22 points wide.
    static func barWidth(minimumGapFraction: Double, plotWidth: CGFloat) -> CGFloat {
        min(max(CGFloat(minimumGapFraction) * plotWidth * 0.62, 3), 22)
    }
}

public struct ScrubChart: View {
    public enum Style: Sendable {
        case line
        case bars
    }

    private let points: [ScrubChartPoint]
    private let domain: ClosedRange<Date>
    private let style: Style
    private let tint: DomainTint
    private let height: CGFloat
    private let maxGapDays: Int
    private let calendar: Calendar
    private let locale: Locale
    private let summary: String
    private let spokenValue: (ScrubChartPoint) -> String
    @Binding private var selection: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var revealed = false
    @State private var adjustReset: Task<Void, Never>?

    /// - Parameters:
    ///   - points: oldest first.
    ///   - domain: the dates the plot spans; the labels sit under it.
    ///   - selection: the index of the point under the finger, nil when none.
    ///   - maxGapDays: a longer stretch with no reading breaks the line instead of bridging it.
    ///   - summary: what VoiceOver says the chart is.
    ///   - spokenValue: what VoiceOver says for the selected point.
    public init(
        points: [ScrubChartPoint],
        domain: ClosedRange<Date>,
        style: Style = .line,
        tint: DomainTint = .workout,
        selection: Binding<Int?>,
        height: CGFloat = 148,
        maxGapDays: Int = 28,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        summary: String,
        spokenValue: @escaping (ScrubChartPoint) -> String
    ) {
        self.points = points
        // A domain of no width still needs somewhere to draw: widen it to a day.
        self.domain = domain.lowerBound < domain.upperBound
            ? domain : domain.lowerBound...domain.lowerBound.addingTimeInterval(86_400)
        self.style = style
        self.tint = tint
        self._selection = selection
        self.height = height
        self.maxGapDays = maxGapDays
        self.calendar = calendar
        self.locale = locale
        self.summary = summary
        self.spokenValue = spokenValue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            plot.frame(height: height)
            dateLabels
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.05)) { revealed = true }
        }
        .onDisappear { adjustReset?.cancel() }
    }

    // MARK: Geometry

    private var values: [Double] { points.map(\.value) }

    /// The vertical scale: bars start at zero, a line takes the data's span with a little air.
    private var axis: TrendsAxis {
        switch style {
        case .bars:
            return TrendsAxis(lower: 0, upper: max((values.max() ?? 1) * 1.08, 1))
        case .line:
            let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            return TrendsAxis.make(
                values: values, baseline: mean, bounds: (-Double.greatestFiniteMagnitude)...Double.greatestFiniteMagnitude)
        }
    }

    private var minimumGapFraction: Double {
        let fractions = points.map { ScrubChartGeometry.unitPosition(of: $0.date, in: domain) }
        let gaps = zip(fractions, fractions.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        return gaps.min() ?? 0.2
    }

    private func plotInset(width: CGFloat) -> CGFloat {
        switch style {
        case .bars: ScrubChartGeometry.barWidth(minimumGapFraction: minimumGapFraction, plotWidth: width) / 2 + 1
        case .line: 5
        }
    }

    private func xs(width: CGFloat) -> [CGFloat] {
        let inset = plotInset(width: width)
        return points.map { inset + (width - inset * 2) * CGFloat(ScrubChartGeometry.unitPosition(of: $0.date, in: domain)) }
    }

    private func y(_ value: Double, height: CGFloat) -> CGFloat {
        // Leave room at the top for the dot's ring and at the bottom for the line's stroke.
        let top: CGFloat = 6
        let usable = max(height - top - 3, 1)
        return top + usable * CGFloat(1 - axis.unit(value))
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            layers(size: proxy.size)
                .contentShape(Rectangle())
                .holdToScrub(
                    onScrub: { location in
                        let index = ScrubChartGeometry.nearestIndex(toX: location.x, in: xs(width: proxy.size.width))
                        if index != selection { selection = index }
                    },
                    onEnd: { selection = nil }
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityValue(selection.flatMap { points.indices.contains($0) ? spokenValue(points[$0]) : nil } ?? "")
        .accessibilityHint(Text("Swipe up or down to step through days"))
        .accessibilityAdjustableAction { direction in
            guard !points.isEmpty else { return }
            let current = selection ?? points.count - 1
            switch direction {
            case .increment: selection = min(current + 1, points.count - 1)
            case .decrement: selection = max(current - 1, 0)
            @unknown default: break
            }
            scheduleAdjustReset()
        }
    }

    /// VoiceOver has no "adjust ended" callback, so the stepped reading clears itself a few seconds after the last step.
    private func scheduleAdjustReset() {
        adjustReset?.cancel()
        adjustReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(StrandMotion.interactive) { selection = nil }
        }
    }

    @ViewBuilder
    private func layers(size: CGSize) -> some View {
        let xs = xs(width: size.width)
        let ys = points.map { y($0.value, height: size.height) }
        let rendered = zip(xs, ys).map { CGPoint(x: $0, y: $1) }
        ZStack {
            switch style {
            case .line: lineLayers(rendered: rendered, height: size.height)
            case .bars: barLayers(rendered: rendered, size: size)
            }
            if let selection, rendered.indices.contains(selection) {
                let spot = rendered[selection]
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: spot.x, y: size.height / 2)
                if style == .line {
                    Circle()
                        .fill(tint.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                        .position(spot)
                }
            }
        }
    }

    private func dayIndices() -> [Int] {
        points.map { calendar.dateComponents([.day], from: domain.lowerBound, to: $0.date).day ?? 0 }
    }

    @ViewBuilder
    private func lineLayers(rendered: [CGPoint], height: CGFloat) -> some View {
        let runs = TrendCurve.runs(dayIndices: dayIndices(), maxGapDays: maxGapDays)
        let line = linePath(rendered, runs: runs)
        let area = areaPath(rendered, runs: runs, height: height)
        let singletons = Set(runs.filter { $0.count == 1 }.map(\.lowerBound))
        ZStack {
            if rendered.count >= 2 {
                area
                    .fill(LinearGradient(colors: [tint.accent.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                    .opacity(revealed ? 1 : 0)
                line
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(
                        LinearGradient(colors: [tint.accent.opacity(0.55), tint.accent], startPoint: .bottom, endPoint: .top),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
            // One dot per reading while the series is short enough to read them, and always one for a day the line
            // cannot reach.
            ForEach(rendered.indices.filter { rendered.count <= 35 || singletons.contains($0) }, id: \.self) { index in
                Circle()
                    .fill(tint.accent)
                    .frame(width: 4, height: 4)
                    .position(rendered[index])
                    .opacity(revealed ? 1 : 0)
            }
            if revealed, selection == nil, let end = rendered.last {
                Circle()
                    .fill(tint.accent)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
            }
        }
    }

    private func barLayers(rendered: [CGPoint], size: CGSize) -> some View {
        let barWidth = ScrubChartGeometry.barWidth(minimumGapFraction: minimumGapFraction, plotWidth: size.width)
        return ZStack {
            // A baseline for the bars to stand on.
            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            }
            .stroke(StrandPalette.hairline, lineWidth: 1)
            ForEach(rendered.indices, id: \.self) { index in
                let top = rendered[index].y
                let barHeight = max(size.height - top, 2)
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                    .fill(tint.accent.opacity(selection == nil || selection == index ? 0.92 : 0.38))
                    .frame(width: barWidth, height: revealed ? barHeight : 2)
                    .position(x: rendered[index].x, y: size.height - (revealed ? barHeight : 2) / 2)
            }
        }
    }

    private func linePath(_ rendered: [CGPoint], runs: [Range<Int>]) -> Path {
        var path = Path()
        for run in runs where run.count >= 2 {
            TrendCurve.append(Array(rendered[run]), to: &path)
        }
        return path
    }

    private func areaPath(_ rendered: [CGPoint], runs: [Range<Int>], height: CGFloat) -> Path {
        var path = Path()
        for run in runs where run.count >= 2 {
            let slice = Array(rendered[run])
            TrendCurve.append(slice, to: &path)
            if let first = slice.first, let last = slice.last {
                path.addLine(to: CGPoint(x: last.x, y: height))
                path.addLine(to: CGPoint(x: first.x, y: height))
                path.closeSubpath()
            }
        }
        return path
    }

    // MARK: Date labels

    private var dateLabels: some View {
        let count = ScrubChartGeometry.labelCount(isAccessibilitySize: typeSize.isAccessibilitySize)
        let dates = ScrubChartGeometry.labelDates(in: domain, count: count)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                Text(verbatim: label(for: date))
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : index == dates.count - 1 ? .trailing : .center)
            }
        }
        .accessibilityHidden(true)
    }

    private func label(for date: Date) -> String {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let style: Date.FormatStyle = span > 366 * 86_400
            ? .dateTime.month(.abbreviated).year()
            : .dateTime.month(.abbreviated).day()
        return date.formatted(style.locale(locale))
    }
}
