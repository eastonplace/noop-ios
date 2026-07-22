import SwiftUI

// MARK: - Trends V2 (NOOP scope, data-rich tier)
//
// The Trends tab, re-spoken in the Sleep/Stress paper dialect. Detail in every layer:
// the hero panel shades your typical zone behind the line, rules the dashed baseline,
// and scrubs under a finger with the shared crosshair/tooltip grammar; a month reads as
// a heat grid with today ringed; delta rows ride the production Sparkline; and
// the weekday read carries its own average rule and marks the current weekday. Replaces
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

    public var averageHeading: String {
        "AVERAGE · LAST \(days) DAYS"
    }

    public var summarySubtitle: String {
        "Last \(days) days · vs prior \(days)"
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
    /// One fixed slot per calendar day. Nil values stay selectable as honest gaps.
    let days: [CalendarMetricDay]
    let dateDomain: ClosedRange<Date>
    let referenceDate: Date
    let calendar: Calendar
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
    /// Exact calendar slot under the finger while scrubbing, nil when idle.
    @State private var scrubDay: CalendarMetricDay? = nil
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

    private var points: [TrendPoint] {
        days.compactMap { day in day.value.map { TrendPoint(date: day.date, value: $0) } }
    }
    private var values: [Double] { points.map(\.value) }
    private var last: Double { points.last?.value ?? 0 }
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
            if let scrubDay {
                Text(scrubDay.value.map { "\(valueFormat($0))\(unitSuffix)" } ?? "No data")
                    .font(StrandFont.captionNumber)
                    .monospacedDigit()
                    .foregroundStyle(scrubDay.value == nil ? StrandPalette.textTertiary : tint)
                Text(TrendCalendar.relativeLabel(
                    for: scrubDay.date,
                    relativeTo: referenceDate,
                    calendar: calendar
                ))
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
        .animation(StrandMotion.fade, value: scrubDay)
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
                .onChangeCompat(of: size.width) { plotWidth = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func plotLayers(size: CGSize) -> some View {
        let yr = yRange
        let ySpan = max(yr.upperBound - yr.lowerBound, 0.0001)
        let xOf: (Date) -> CGFloat = {
            size.width * CGFloat(TrendCalendar.unitPosition(of: $0, in: dateDomain))
        }
        let yOf: (Double) -> CGFloat = { size.height - size.height * CGFloat(($0 - yr.lowerBound) / ySpan) }
        let rendered = points.map { (xOf($0.date), yOf($0.value)) }

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

            if revealed, scrubDay == nil, let lastPoint = rendered.last {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                    .position(x: lastPoint.0, y: lastPoint.1)
                    .transition(.opacity)
            }

            // Scrub crosshair + dot + tooltip — the shared readout grammar.
            if let scrubDay {
                let scrubX = xOf(scrubDay.date)
                let scrubY = scrubDay.value.map(yOf) ?? baselineY
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: scrubX, y: size.height / 2)
                if scrubDay.value != nil {
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .position(x: scrubX, y: scrubY)
                }
                ChartTooltip(
                    value: scrubDay.value.map { "\(valueFormat($0))\(unitSuffix)" } ?? "No data",
                    label: TrendCalendar.relativeLabel(
                        for: scrubDay.date,
                        relativeTo: referenceDate,
                        calendar: calendar
                    ),
                    accent: scrubDay.value == nil ? nil : tint
                )
                .position(
                    ChartTooltipPlacement.position(
                        anchor: CGPoint(x: scrubX, y: scrubY),
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
                guard plotWidth > 0, !days.isEmpty else { return }
                let fraction = min(max(Double(drag.location.x / plotWidth), 0), 1)
                guard let day = TrendCalendar.day(atUnitPosition: fraction, in: days) else { return }
                if day != scrubDay {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrubDay = day }
                    StrandHaptic.selection.play()
                }
            }
            .onEnded { _ in
                withAnimation(StrandMotion.interactive) { scrubDay = nil }
            }
    }

    private var axis: some View {
        HStack {
            Text(Self.axisFormatter.string(from: dateDomain.lowerBound))
            Spacer()
            Text(TrendCalendar.relativeLabel(
                for: dateDomain.upperBound,
                relativeTo: referenceDate,
                calendar: calendar
            ))
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
        "Trend, latest \(valueFormat(last))\(unitSuffix), baseline \(valueFormat(baseline)), typical \(valueFormat(typical.lowerBound)) to \(valueFormat(typical.upperBound)), \(points.count) scored days and \(days.filter { $0.value == nil }.count) missing days shown from \(Self.axisFormatter.string(from: dateDomain.lowerBound)) to \(Self.axisFormatter.string(from: dateDomain.upperBound))."
    }

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

// MARK: - TrendMonthHeat

public enum TrendHeatColorScale: Sendable {
    case intensity
    case recoveryBands
}

/// One real calendar date in a trend heatmap. A nil value means the metric was not
/// calculated for that date; the date itself is never removed from the sequence.
public struct CalendarMetricDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double?

    public var id: Date { date }

    public init(date: Date, value: Double?) {
        self.date = date
        self.value = value
    }
}

/// Source-compatible name retained for the completed Spec 014 Trends API.
public typealias TrendCalendarDay = CalendarMetricDay

public enum TrendCalendarCellState: Equatable, Sendable {
    case value(Double)
    case missing
    case future
}

public struct TrendCalendarBest: Equatable, Sendable {
    public let date: Date
    public let value: Double
    public let daysAgo: Int
}

/// Pure calendar layout and aggregation used by Trends. Calendar arithmetic is
/// intentionally centralized here so chart views never compact away missing dates.
public enum TrendCalendar {
    public static func mondayFirstWeekdayIndex(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    public static func buildRollingWindow(
        observations: [CalendarMetricDay],
        through referenceDate: Date,
        count: Int,
        calendar sourceCalendar: Calendar = .autoupdatingCurrent
    ) -> [CalendarMetricDay] {
        guard count > 0 else { return [] }
        var calendar = sourceCalendar
        calendar.firstWeekday = 2
        let end = calendar.startOfDay(for: referenceDate)
        guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) else { return [] }
        return slots(observations: observations, start: start, count: count, calendar: calendar)
    }

    public static func buildWeekWindow(
        observations: [CalendarMetricDay],
        containing referenceDate: Date,
        calendar sourceCalendar: Calendar = .autoupdatingCurrent
    ) -> [CalendarMetricDay] {
        var calendar = sourceCalendar
        calendar.firstWeekday = 2
        let anchor = calendar.startOfDay(for: referenceDate)
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start else { return [] }
        return slots(observations: observations, start: monday, count: 7, calendar: calendar)
    }

    public static func value(
        on date: Date,
        in days: [CalendarMetricDay],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Double? {
        days.first(where: { calendar.isDate($0.date, inSameDayAs: date) })?.value
    }

    public static func mean(of days: [CalendarMetricDay]) -> Double? {
        let values = days.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public static func dateDomain(
        through referenceDate: Date,
        count: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ClosedRange<Date>? {
        guard count > 0 else { return nil }
        let end = calendar.startOfDay(for: referenceDate)
        guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) else { return nil }
        return start...end
    }

    /// A calendar-day range whose offset is measured in whole periods. Offset
    /// zero ends on the reference day; -1 is the immediately preceding,
    /// non-overlapping period of exactly the same length.
    public static func equalLengthPeriod(
        through referenceDate: Date,
        count: Int,
        periodOffset: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ClosedRange<Date>? {
        guard count > 0 else { return nil }
        let reference = calendar.startOfDay(for: referenceDate)
        guard let end = calendar.date(byAdding: .day, value: periodOffset * count, to: reference),
              let start = calendar.date(byAdding: .day, value: -(count - 1), to: end)
        else { return nil }
        return start...end
    }

    public static func relativeLabel(
        for date: Date,
        relativeTo referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let target = calendar.startOfDay(for: date)
        let reference = calendar.startOfDay(for: referenceDate)
        let difference = calendar.dateComponents([.day], from: target, to: reference).day ?? 0
        if difference == 0 { return String(localized: "Today", bundle: .module) }
        if difference == 1 { return String(localized: "Yesterday", bundle: .module) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: target)
    }

    public static func unitPosition(of date: Date, in domain: ClosedRange<Date>) -> Double {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return 0.5 }
        return min(max(date.timeIntervalSince(domain.lowerBound) / span, 0), 1)
    }

    /// Maps a horizontal scrub position to a fixed calendar slot, including nil gaps.
    public static func day(
        atUnitPosition position: Double,
        in days: [CalendarMetricDay]
    ) -> CalendarMetricDay? {
        guard !days.isEmpty else { return nil }
        let fraction = min(max(position, 0), 1)
        let index = Int((fraction * Double(days.count - 1)).rounded())
        return days[index]
    }

    /// Maps a horizontal touch to one of seven Monday-first weekday slots.
    public static func weekdayIndex(atUnitPosition position: Double) -> Int {
        let fraction = min(max(position, 0), 1)
        return Int((fraction * 6).rounded())
    }

    /// Maps a normalized grid touch to its exact row-major calendar cell.
    public static func gridIndex(
        xFraction: Double,
        yFraction: Double,
        columns: Int,
        count: Int
    ) -> Int? {
        guard columns > 0, count > 0 else { return nil }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let x = min(max(xFraction, 0), 1)
        let y = min(max(yFraction, 0), 1)
        let column = min(Int(x * Double(columns)), columns - 1)
        let row = min(Int(y * Double(rows)), rows - 1)
        let index = row * columns + column
        return index < count ? index : nil
    }

    public static func buildFiveWeekWindow(
        observations: [TrendCalendarDay],
        through referenceDate: Date,
        calendar sourceCalendar: Calendar = .autoupdatingCurrent
    ) -> [TrendCalendarDay] {
        var calendar = sourceCalendar
        calendar.firstWeekday = 2 // Monday
        let today = calendar.startOfDay(for: referenceDate)
        guard let currentMonday = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let firstMonday = calendar.date(byAdding: .day, value: -28, to: currentMonday) else {
            return []
        }

        var valuesByDate: [Date: Double?] = [:]
        for observation in observations {
            valuesByDate[calendar.startOfDay(for: observation.date)] = observation.value
        }

        return (0..<35).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstMonday) else { return nil }
            let value = date > today ? nil : (valuesByDate[date] ?? nil)
            return TrendCalendarDay(date: date, value: value)
        }
    }

    public static func cellState(
        for day: TrendCalendarDay,
        today referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TrendCalendarCellState {
        let today = calendar.startOfDay(for: referenceDate)
        let date = calendar.startOfDay(for: day.date)
        if date > today { return .future }
        if let value = day.value { return .value(value) }
        return .missing
    }

    public static func best(
        in days: [TrendCalendarDay],
        relativeTo referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TrendCalendarBest? {
        let scored = days.compactMap { day -> (Date, Double)? in
            day.value.map { (calendar.startOfDay(for: day.date), $0) }
        }
        guard let best = scored.max(by: { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }) else { return nil }
        let today = calendar.startOfDay(for: referenceDate)
        let age = calendar.dateComponents([.day], from: best.0, to: today).day ?? 0
        return TrendCalendarBest(date: best.0, value: best.1, daysAgo: max(0, age))
    }

    /// Seven Monday-first averages. Nil means that weekday has no scored observations.
    public static func weekdayAverages(
        _ days: [TrendCalendarDay],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Double?] {
        var values = Array(repeating: [Double](), count: 7)
        for day in days {
            guard let value = day.value else { continue }
            let mondayFirstIndex = mondayFirstWeekdayIndex(for: day.date, calendar: calendar)
            values[mondayFirstIndex].append(value)
        }
        return values.map { bucket in
            bucket.isEmpty ? nil : bucket.reduce(0, +) / Double(bucket.count)
        }
    }

    private static func slots(
        observations: [CalendarMetricDay],
        start: Date,
        count: Int,
        calendar: Calendar
    ) -> [CalendarMetricDay] {
        var valuesByDate: [Date: Double?] = [:]
        for observation in observations {
            valuesByDate[calendar.startOfDay(for: observation.date)] = observation.value
        }
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return CalendarMetricDay(date: date, value: valuesByDate[date] ?? nil)
        }
    }
}

/// The last 35 days as a heat grid with Monday columns and the real current day ringed.
public struct TrendMonthHeat: View {
    /// Exactly five Monday-first calendar weeks. Missing dates remain present with nil values.
    let days: [TrendCalendarDay]
    let tint: Color
    let referenceDate: Date
    let calendar: Calendar
    var valueFormat: (Double) -> String
    var colorScale: TrendHeatColorScale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var scrubIndex: Int? = nil

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
            if let scrubIndex, days.indices.contains(scrubIndex) {
                let day = days[scrubIndex]
                Text("\(TrendCalendar.relativeLabel(for: day.date, relativeTo: referenceDate, calendar: calendar)) · \(day.value.map(valueFormat) ?? "No data")")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(day.value == nil ? StrandPalette.textTertiary : tint)
            } else if let best = TrendCalendar.best(in: days, relativeTo: referenceDate, calendar: calendar) {
                Text("Best \(valueFormat(best.value)) · \(best.daysAgo) days ago")
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
        let values = days.compactMap(\.value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, 0.0001)
        let today = calendar.startOfDay(for: referenceDate)

        return GeometryReader { proxy in
            ZStack {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(days) { day in
                        let index = days.firstIndex(where: { $0.id == day.id }) ?? 0
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(cellColor(for: day, low: lo, span: span))
                            .frame(height: 22)
                            .overlay {
                                if calendar.isDate(today, inSameDayAs: day.date) || scrubIndex == index {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(
                                            StrandPalette.textPrimary.opacity(scrubIndex == index ? 0.95 : 0.6),
                                            lineWidth: scrubIndex == index ? 1.8 : 1.2
                                        )
                                }
                            }
                            .opacity(revealed ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : StrandMotion.fade.delay(Double(index) * 0.008),
                                value: revealed
                            )
                    }
                }
                if let scrubIndex, days.indices.contains(scrubIndex) {
                    let columns = 7
                    let rows = max(Int(ceil(Double(days.count) / Double(columns))), 1)
                    let column = scrubIndex % columns
                    let row = scrubIndex / columns
                    let anchor = CGPoint(
                        x: (CGFloat(column) + 0.5) * proxy.size.width / CGFloat(columns),
                        y: (CGFloat(row) + 0.5) * proxy.size.height / CGFloat(rows)
                    )
                    let day = days[scrubIndex]
                    ChartTooltip(
                        value: day.value.map(valueFormat) ?? "No data",
                        label: TrendCalendar.relativeLabel(
                            for: day.date,
                            relativeTo: referenceDate,
                            calendar: calendar
                        ),
                        accent: day.value == nil ? nil : tint
                    )
                    .position(
                        ChartTooltipPlacement.position(
                            anchor: anchor,
                            tooltipSize: CGSize(width: 104, height: 40),
                            in: proxy.size
                        )
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard proxy.size.width > 0, proxy.size.height > 0 else { return }
                        let index = TrendCalendar.gridIndex(
                            xFraction: Double(drag.location.x / proxy.size.width),
                            yFraction: Double(drag.location.y / proxy.size.height),
                            columns: 7,
                            count: days.count
                        )
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
            )
        }
        .frame(height: 126)
    }

    private func cellColor(for day: TrendCalendarDay, low: Double, span: Double) -> Color {
        switch TrendCalendar.cellState(for: day, today: referenceDate, calendar: calendar) {
        case .value(let value): cellColor(for: value, low: low, span: span)
        case .missing: StrandPalette.surfaceInset
        case .future: StrandPalette.surfaceInset.opacity(0.35)
        }
    }

    private func cellColor(for value: Double, low: Double, span: Double) -> Color {
        switch colorScale {
        case .intensity:
            return tint.opacity(0.12 + 0.78 * (value - low) / span)
        case .recoveryBands:
            return RecoveryBands.color(for: value)
        }
    }

    private var accessibilitySummary: String {
        let values = days.compactMap(\.value)
        guard let best = values.max() else { return "No month data yet." }
        let average = values.reduce(0, +) / Double(max(values.count, 1))
        let states = days.map { TrendCalendar.cellState(for: $0, today: referenceDate, calendar: calendar) }
        let missing = states.filter { $0 == .missing }.count
        let future = states.filter { $0 == .future }.count
        return "Last 35 calendar days, \(values.count) scored, \(missing) missing, \(future) upcoming, average \(valueFormat(average)), best \(valueFormat(best))."
    }
}

// MARK: - TrendDeltaRow

public enum TrendDeltaTone: Sendable {
    case positive
    case negative
    case neutral
}

/// One metric's compact trend read: range-wide sparkline, latest value, prior-period delta.
public struct TrendDeltaRow: View {
    let label: String
    let subtitle: String
    let values: [Double]
    let latest: String
    let delta: String
    let tone: TrendDeltaTone
    let tint: Color

    private var deltaColor: Color {
        switch tone {
        case .positive: StrandPalette.statusPositive
        case .negative: StrandPalette.metricRose
        case .neutral: StrandPalette.textSecondary
        }
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 8)
            if values.count > 1 {
                Sparkline(
                    values: values,
                    gradient: Gradient(colors: [tint.opacity(0.40), tint]),
                    lineWidth: 2,
                    showsArea: true,
                    showsHead: true,
                    showsHover: false
                )
                .frame(width: 78, height: 26)
                .accessibilityHidden(true)
            } else {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                        .frame(height: 2)
                    if !values.isEmpty {
                        Circle().fill(tint).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 78, height: 26)
                .accessibilityHidden(true)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(latest)
                    .font(StrandFont.number(17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(delta)
                    .font(StrandFont.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(latest), \(delta), \(subtitle)")
    }
}

// MARK: - TrendWeekdayBars

public struct TrendWeekdayBars: View {
    /// Seven optional averages, Monday-first, on the metric's own scale.
    let values: [Double?]
    let tint: Color
    let referenceDate: Date
    let calendar: Calendar
    var valueFormat: (Double) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var scrubIndex: Int? = nil

    private static let labels = ["M", "T", "W", "T", "F", "S", "S"]
    private static let fullLabels = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let count = 7
                let slot = proxy.size.width / CGFloat(count)
                let barWidth = max(6, slot * 0.42)
                let scored = values.compactMap { $0 }
                let top = scored.max() ?? 1
                let bottom = scored.min() ?? 0
                let span = max(top - bottom, 0.0001)
                let average = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)
                let currentWeekday = TrendCalendar.mondayFirstWeekdayIndex(
                    for: referenceDate, calendar: calendar
                )
                let plotHeight = max(54, proxy.size.height - 30)
                let heightOf: (Double) -> CGFloat = { value in
                    max(6, CGFloat(0.25 + 0.75 * (value - bottom) / span) * plotHeight)
                }

                ZStack(alignment: .topLeading) {
                    let avgY = 12 + plotHeight - heightOf(average)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: avgY))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: avgY))
                    }
                    .stroke(
                        StrandPalette.hairlineStrong.opacity(0.9),
                        style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                    )
                    if scrubIndex == nil {
                        Text("avg \(valueFormat(average))")
                            .font(StrandFont.micro)
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary)
                            .position(x: 28, y: max(7, avgY - 8))
                    }

                    ForEach(0..<7, id: \.self) { index in
                        let value = values[index]
                        let height = value.map(heightOf) ?? 6
                        let x = slot * CGFloat(index) + slot / 2
                        let isSelected = scrubIndex == index
                        Capsule(style: .continuous)
                            .fill(barColor(value: value, isCurrent: index == currentWeekday, isSelected: isSelected))
                            .frame(width: barWidth, height: revealed ? height : 6)
                            .overlay {
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .stroke(StrandPalette.textPrimary.opacity(0.9), lineWidth: 1.5)
                                }
                            }
                            .position(x: x, y: 12 + plotHeight - (revealed ? height : 6) / 2)
                            .animation(
                                reduceMotion ? nil : StrandMotion.value.delay(Double(index) * 0.03),
                                value: revealed
                            )
                        Text(Self.labels[index])
                            .font(StrandFont.micro.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected || index == currentWeekday
                                ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .position(x: x, y: 12 + plotHeight + 10)
                    }

                    if let scrubIndex, values.indices.contains(scrubIndex) {
                        let value = values[scrubIndex]
                        let height = value.map(heightOf) ?? 6
                        let x = slot * CGFloat(scrubIndex) + slot / 2
                        let anchor = CGPoint(x: x, y: 12 + plotHeight - height)
                        ChartTooltip(
                            value: value.map(valueFormat) ?? "No data",
                            label: Self.fullLabels[scrubIndex],
                            accent: value == nil ? nil : tint
                        )
                        .position(
                            ChartTooltipPlacement.position(
                                anchor: anchor,
                                tooltipSize: CGSize(width: 104, height: 40),
                                in: proxy.size
                            )
                        )
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard proxy.size.width > 0 else { return }
                            let fraction = Double(drag.location.x / proxy.size.width)
                            let index = TrendCalendar.weekdayIndex(atUnitPosition: fraction)
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
                )
            }
            HStack(spacing: 7) {
                Image(systemName: "hand.draw")
                    .font(StrandFont.micro.weight(.semibold))
                if let scrubIndex, values.indices.contains(scrubIndex) {
                    Text("\(Self.fullLabels[scrubIndex]) · \(values[scrubIndex].map(valueFormat) ?? "No data")")
                        .monospacedDigit()
                } else {
                    Text("Touch and drag to read a weekday")
                }
                Spacer(minLength: 0)
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func barColor(value: Double?, isCurrent: Bool, isSelected: Bool) -> Color {
        guard value != nil else {
            return isSelected || isCurrent
                ? StrandPalette.textPrimary.opacity(0.16)
                : StrandPalette.surfaceInset
        }
        if isSelected { return tint }
        return tint.opacity(isCurrent ? 0.82 : 0.46)
    }

    private var accessibilitySummary: String {
        let current = TrendCalendar.mondayFirstWeekdayIndex(for: referenceDate, calendar: calendar)
        let summary = zip(Self.fullLabels, values).map { name, value in
            "\(name) \(value.map(valueFormat) ?? "missing")"
        }.joined(separator: ", ")
        return "Average by weekday. Today is \(Self.fullLabels[current]). \(summary). Touch and drag to inspect each weekday."
    }
}
