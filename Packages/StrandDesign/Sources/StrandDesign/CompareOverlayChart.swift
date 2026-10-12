import SwiftUI

// MARK: - Trend cadence

/// How often a series is recorded, so a weekly or sparse series still draws one connected line.
public enum TrendCadence {
    /// The longest stretch a chart's line bridges for a daily series.
    public static let dailyGapLimit = 3

    /// The gap limit for a series recorded on these day offsets (ascending): three times the usual spacing between
    /// readings, never under the daily limit. Daily data keeps three days; weekly data bridges up to three weeks.
    public static func gapLimitDays(dayOffsets: [Int]) -> Int {
        let gaps = zip(dayOffsets.dropFirst(), dayOffsets).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return dailyGapLimit }
        return max(dailyGapLimit, gaps[gaps.count / 2] * 3)
    }
}

// MARK: - Compare overlay chart
//
// Two to four metrics on one plot, each scaled to its own range so different units share a vertical axis. It is the
// Coach/Trends chart recipe for several series: a tinted line per series (the first over a 14% wash when there are only
// two), at most four evenly spaced date labels, a glowing end cap on each series' latest reading, and touch-and-hold-then-
// drag to read any day. Like `ScrubChart`, it draws nothing but the plot: it reports the day under the finger through
// `selection` and the caller turns that into the real values, in words.

/// The geometry the overlay needs, kept apart from the view so it can be tested without drawing.
enum CompareOverlayGeometry {
    /// Every day any series has a reading on, ascending, once each.
    static func days(of series: [CompareSeries]) -> [Date] {
        Array(Set(series.flatMap { $0.points.map(\.date) })).sorted()
    }

    /// The line to draw for one series, and the unbroken stretches of it. Gaps are read off the readings themselves (the
    /// series' own cadence, `gapLimit`), and only then is each long stretch thinned to a min/max-bucketed copy of its own.
    /// Thinning first and reading gaps afterwards would see the wider spacing of the thinned points as missing data and
    /// cut a daily series of a few years into fragments and dots.
    ///
    /// - Parameters:
    ///   - points: the series' readings, ascending.
    ///   - dayOffsets: each reading's whole-day distance from one fixed day, in the same order.
    ///   - gapLimit: the longest stretch of days the line bridges (`TrendCadence.gapLimitDays` for these offsets).
    static func drawnLine(points: [TrendPoint], dayOffsets: [Int], gapLimit: Int) -> (drawn: [TrendPoint], runs: [Range<Int>]) {
        guard points.count == dayOffsets.count, !points.isEmpty else { return (points, points.isEmpty ? [] : [0..<points.count]) }
        var drawn: [TrendPoint] = []
        var runs: [Range<Int>] = []
        drawn.reserveCapacity(min(points.count, ChartDownsample.targetVertices * 2))
        for run in TrendCurve.runs(dayIndices: dayOffsets, maxGapDays: gapLimit) {
            // A run's share of the vertex budget follows its share of the readings.
            let share = Int((Double(ChartDownsample.targetVertices) * Double(run.count) / Double(points.count)).rounded(.up))
            let kept = ChartDownsample.minMaxBucketed(
                Array(points[run]), threshold: ChartDownsample.markThreshold, targetCount: max(share, 4))
            runs.append(drawn.count..<(drawn.count + kept.count))
            drawn.append(contentsOf: kept)
        }
        return (drawn, runs)
    }

    /// The span the plot covers: first to last reading across all the series, never narrower than a day.
    static func domain(of series: [CompareSeries]) -> ClosedRange<Date>? {
        let all = series.flatMap { $0.points.map(\.date) }
        guard let first = all.min(), let last = all.max() else { return nil }
        return first < last ? first...last : first...first.addingTimeInterval(86_400)
    }
}

public struct CompareOverlayChart: View {
    private struct Line {
        let tint: Color
        /// The normalized (0...1) points to draw: the series itself, or a min/max-bucketed copy of a long one.
        let drawn: [TrendPoint]
        /// The unbroken stretches of `drawn` (indices), cut where the series itself has a gap.
        let runs: [Range<Int>]
        /// The normalized value on each day the series has a reading, for the dot under the finger.
        let byDay: [Date: Double]
        let latest: TrendPoint?
    }

    private let lines: [Line]
    private let days: [Date]
    private let domain: ClosedRange<Date>
    private let height: CGFloat
    private let calendar: Calendar
    private let locale: Locale
    private let summary: String
    private let stepHint: LocalizedStringKey
    private let spokenValue: (Date) -> String
    @Binding private var selection: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var revealed = false
    @State private var adjustReset: Task<Void, Never>?

    /// - Parameters:
    ///   - series: two to four, each with its own tint and its readings.
    ///   - selection: the day under the finger (one of the days the series have readings on), nil when none.
    ///   - summary: what VoiceOver says the chart is.
    ///   - spokenValue: what VoiceOver says for the selected day.
    public init(
        series: [CompareSeries],
        selection: Binding<Date?>,
        height: CGFloat = 164,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        summary: String,
        stepHint: LocalizedStringKey = "Swipe up or down to step through days",
        spokenValue: @escaping (Date) -> String
    ) {
        self._selection = selection
        self.height = height
        self.calendar = calendar
        self.locale = locale
        self.summary = summary
        self.stepHint = stepHint
        self.spokenValue = spokenValue
        self.days = CompareOverlayGeometry.days(of: series)
        let domain = CompareOverlayGeometry.domain(of: series) ?? Date()...Date().addingTimeInterval(86_400)
        self.domain = domain
        self.lines = series.map { entry in
            let normalized = entry.points.map { TrendPoint(date: $0.date, value: entry.normalized($0.value)) }
            let offsets = entry.points.map { calendar.dateComponents([.day], from: domain.lowerBound, to: $0.date).day ?? 0 }
            let line = CompareOverlayGeometry.drawnLine(
                points: normalized, dayOffsets: offsets, gapLimit: TrendCadence.gapLimitDays(dayOffsets: offsets))
            return Line(
                tint: entry.tint,
                drawn: line.drawn,
                runs: line.runs,
                byDay: Dictionary(normalized.map { ($0.date, $0.value) }, uniquingKeysWith: { _, later in later }),
                latest: normalized.last)
        }
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

    private static let inset: CGFloat = 5

    private func x(of date: Date, width: CGFloat) -> CGFloat {
        Self.inset + (width - Self.inset * 2) * CGFloat(ScrubChartGeometry.unitPosition(of: date, in: domain))
    }

    private func y(_ unit: Double, height: CGFloat) -> CGFloat {
        let top: CGFloat = 6
        let usable = max(height - top - 3, 1)
        return top + usable * CGFloat(1 - unit)
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            layers(size: proxy.size)
                .contentShape(Rectangle())
                .holdToScrub(
                    onScrub: { location in
                        let xs = days.map { x(of: $0, width: proxy.size.width) }
                        let index = ScrubChartGeometry.nearestIndex(toX: location.x, in: xs)
                        let day = index.map { days[$0] }
                        if day != selection { selection = day }
                    },
                    onEnd: { selection = nil }
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityValue(selection.map(spokenValue) ?? "")
        .accessibilityHint(Text(stepHint))
        .accessibilityAdjustableAction { direction in
            guard !days.isEmpty else { return }
            let current = selection.flatMap { days.firstIndex(of: $0) } ?? days.count - 1
            switch direction {
            case .increment: selection = days[min(current + 1, days.count - 1)]
            case .decrement: selection = days[max(current - 1, 0)]
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
        ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                lineLayers(line, showsWash: index == 0 && lines.count == 2, size: size)
            }
            if let selection {
                let cx = x(of: selection, width: size.width)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: cx, y: size.height / 2)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let unit = line.byDay[selection] {
                        Circle()
                            .fill(line.tint)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                            .position(x: cx, y: y(unit, height: size.height))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lineLayers(_ line: Line, showsWash: Bool, size: CGSize) -> some View {
        let rendered = line.drawn.map { CGPoint(x: x(of: $0.date, width: size.width), y: y($0.value, height: size.height)) }
        let runs = line.runs
        let singletons = Set(runs.filter { $0.count == 1 }.map(\.lowerBound))
        ZStack {
            if rendered.count >= 2 {
                if showsWash {
                    areaPath(rendered, runs: runs, height: size.height)
                        .fill(LinearGradient(colors: [line.tint.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                        .opacity(revealed ? 1 : 0)
                }
                linePath(rendered, runs: runs)
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(line.tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            // A reading the line cannot reach (a gap either side) is a dot of its own.
            ForEach(Array(singletons).sorted(), id: \.self) { index in
                Circle()
                    .fill(line.tint)
                    .frame(width: 4, height: 4)
                    .position(rendered[index])
                    .opacity(revealed ? 1 : 0)
            }
            if revealed, selection == nil, let end = rendered.last {
                Circle()
                    .fill(line.tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
            }
        }
    }

    private func linePath(_ rendered: [CGPoint], runs: [Range<Int>]) -> Path {
        var path = Path()
        for run in runs where run.count >= 2 { TrendCurve.append(Array(rendered[run]), to: &path) }
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
