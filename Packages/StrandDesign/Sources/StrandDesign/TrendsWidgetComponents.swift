import SwiftUI

// MARK: - Trends in the widget design language
//
// The Trends tab root, re-spoken in the language of the Today widgets and the Coach cards: flat sections
// opened by an eyebrow, one `DomainTint` per metric, a tinted line over a 14%-to-clear wash, at most four
// evenly spaced date labels, rails whose labels knock the canvas out of the line, and quiet state pills.
//
// These are additive: `TrendPanelChart`, `TrendMonthHeat`, `TrendWeekdayBars` and `TrendDeltaRow` (the
// previous generation) are untouched and still serve the metric-compare and report screens.

// MARK: - Curve

/// Monotone cubic interpolation for a daily series.
///
/// A plain Catmull-Rom spline overshoots past the data on a sharp turn and invents spikes that were never
/// measured. A monotone cubic Hermite spline (Fritsch-Butland tangents) stays inside the vertical span of
/// the two samples it joins, so every peak and trough on screen is a real day.
enum TrendCurve {
    /// Appends one sub-path through `points` (x strictly increasing) to `path`.
    static func append(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        let count = points.count
        guard count > 1 else { return }

        var widths = [CGFloat](repeating: 0, count: count - 1)
        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            widths[index] = points[index + 1].x - points[index].x
            slopes[index] = widths[index] > 0
                ? (points[index + 1].y - points[index].y) / widths[index]
                : 0
        }
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                let before = slopes[index - 1]
                let after = slopes[index]
                if before * after <= 0 {
                    tangents[index] = 0
                } else {
                    let w1 = 2 * widths[index] + widths[index - 1]
                    let w2 = widths[index] + 2 * widths[index - 1]
                    tangents[index] = (w1 + w2) / (w1 / before + w2 / after)
                }
            }
        }
        for index in 0..<(count - 1) {
            let third = widths[index] / 3
            path.addCurve(
                to: points[index + 1],
                control1: CGPoint(x: points[index].x + third, y: points[index].y + tangents[index] * third),
                control2: CGPoint(x: points[index + 1].x - third, y: points[index + 1].y - tangents[index + 1] * third)
            )
        }
    }

    /// Index ranges of unbroken runs. A gap of more than `maxGapDays` between neighbouring samples starts a
    /// new run, so a long stretch with no data reads as a gap instead of a bridged line.
    static func runs(dayIndices: [Int], maxGapDays: Int) -> [Range<Int>] {
        guard !dayIndices.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        for index in 1..<max(dayIndices.count, 1) where dayIndices[index] - dayIndices[index - 1] > maxGapDays {
            result.append(start..<index)
            start = index
        }
        result.append(start..<dayIndices.count)
        return result
    }
}

// MARK: - Axis

/// The vertical scale of a trend chart: the data's own span with a little air, clamped to what the metric can
/// physically be (a recovery never reads 108%).
struct TrendsAxis: Equatable {
    let lower: Double
    let upper: Double

    func unit(_ value: Double) -> Double {
        guard upper > lower else { return 0.5 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    static func make(values: [Double], baseline: Double, bounds: ClosedRange<Double>) -> TrendsAxis {
        let finite = values.filter(\.isFinite) + (baseline.isFinite ? [baseline] : [])
        var low = finite.min() ?? 0
        var high = finite.max() ?? 1
        if high - low < 1e-9 {
            low -= 0.5
            high += 0.5
        }
        let pad = (high - low) * 0.1
        low = max(low - pad, bounds.lowerBound)
        high = min(high + pad, bounds.upperBound)
        if high - low < 1e-9 { high = low + 1 }
        return TrendsAxis(lower: low, upper: high)
    }
}

// MARK: - Formatting helpers

/// Date formatters, built once per calendar, time zone, locale and template. A `DateFormatter` is costly to make
/// and the scrub readouts ask for one on every step.
final class TrendsDateFormatters: @unchecked Sendable {
    static let shared = TrendsDateFormatters()

    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]

    func string(from date: Date, template: String, calendar: Calendar) -> String {
        let locale = Locale.current
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(locale.identifier)|\(template)"
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            let made = DateFormatter()
            made.calendar = calendar
            made.locale = locale
            made.timeZone = calendar.timeZone
            made.setLocalizedDateFormatFromTemplate(template)
            cache[key] = made
            formatter = made
        }
        return formatter.string(from: date)
    }
}

/// The text that follows a value for its unit. A percent follows the current locale ("85%" in English, "85 %"
/// in German and Spanish) instead of a hard-coded "%"; other units are set off by a space.
public enum TrendsUnitSuffix {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var percentCache: [String: String] = [:]

    public static func text(for unit: String) -> String {
        if unit.isEmpty { return "" }
        return unit == "%" ? percent : " \(unit)"
    }

    private static var percent: String {
        let locale = Locale.current
        lock.lock()
        defer { lock.unlock() }
        if let cached = percentCache[locale.identifier] { return cached }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        // Prefix-style locales have no suffix to borrow; keep the plain sign there.
        let suffix = formatter.positiveSuffix.flatMap { $0.isEmpty ? nil : $0 } ?? "%"
        percentCache[locale.identifier] = suffix
        return suffix
    }
}

/// Weekday names in the current locale, Monday first (the order the calendar and weekday views lay out).
enum TrendsWeekdayNames {
    static func veryShort(calendar: Calendar) -> [String] {
        rotated(localised(calendar).veryShortStandaloneWeekdaySymbols)
    }

    static func full(calendar: Calendar) -> [String] {
        rotated(localised(calendar).standaloneWeekdaySymbols)
    }

    private static func localised(_ calendar: Calendar) -> Calendar {
        var copy = calendar
        copy.locale = .current
        return copy
    }

    /// Symbols run Sunday first; Monday first is the same list with Sunday moved to the end.
    private static func rotated(_ symbols: [String]) -> [String] {
        symbols.count == 7 ? Array(symbols[1...]) + [symbols[0]] : symbols
    }
}

// MARK: - Small shared parts

/// The canvas knock-out behind a rail label: it grows outward from the digits, so they do not move, and a
/// line that passes under a label stays legible and reads as passing behind it.
private extension View {
    func trendsRailKnockout() -> some View {
        self.background {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StrandPalette.appCanvas.opacity(0.88))
                .padding(.horizontal, -3)
                .padding(.vertical, -1)
        }
    }
}

private func trendsFormattedIsZero(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy { "0.,٠٫ +−-".contains($0) }
}

// MARK: - Scrubbing that lets the page scroll

/// Touch-and-hold-then-drag reading for a chart, calendar or bar row that sits inside a vertically scrolling
/// page.
///
/// A touch that starts moving at once is the page scrolling: the press has not rested long enough, so the
/// recogniser fails and the scroll view takes the touch, exactly as it does anywhere else on the screen. A touch
/// that rests for a beat (a tenth of a second) reads the chart under the finger and keeps reading as the finger
/// drags, the way the Stocks chart does. Lifting the finger clears the reading. On iOS this is a UIKit long-press
/// recogniser (allowed to run beside the scroll view's pan); elsewhere it is an immediate drag.
struct TrendsScrubModifier: ViewModifier {
    let onScrub: (CGPoint) -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.overlay(
            TrendsScrubSurface(onScrub: onScrub, onEnd: onEnd)
                .accessibilityHidden(true)
        )
        #else
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onScrub($0.location) }
                .onEnded { _ in onEnd() }
        )
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// A transparent surface carrying the long-press recogniser, laid over the view it reads.
private struct TrendsScrubSurface: UIViewRepresentable {
    let onScrub: (CGPoint) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        recognizer.minimumPressDuration = 0.1
        recognizer.allowableMovement = 8
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onScrub = onScrub
        context.coordinator.onEnd = onEnd
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScrub: (CGPoint) -> Void = { _ in }
        var onEnd: () -> Void = {}

        @MainActor @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onScrub(recognizer.location(in: recognizer.view))
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }

        /// Other recognisers (the scroll view's pan, the navigation pop, a sheet's dismiss) may run beside this one
        /// only until the hold has been recognised. From then on the reading owns the touch, so the page does not
        /// move under the finger.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated { gestureRecognizer.state == .possible }
        }
    }
}
#endif

private extension View {
    func trendsScrub(onScrub: @escaping (CGPoint) -> Void, onEnd: @escaping () -> Void) -> some View {
        modifier(TrendsScrubModifier(onScrub: onScrub, onEnd: onEnd))
    }
}

public extension View {
    /// Touch and hold, then drag, to read a chart that sits inside a vertically scrolling page: a touch that moves at once is
    /// the page scrolling. `onScrub` receives the finger's location in this view; `onEnd` is called when the finger lifts.
    func holdToScrub(onScrub: @escaping (CGPoint) -> Void, onEnd: @escaping () -> Void) -> some View {
        modifier(TrendsScrubModifier(onScrub: onScrub, onEnd: onEnd))
    }
}

// MARK: - Chips

/// The label of the metric menu: the metric's symbol in its domain colour, its name and the up-down chevron,
/// on the same inset capsule as the segmented control it sits beside.
public struct TrendsMenuChipLabel: View {
    private let title: String
    private let systemImage: String
    private let tint: Color
    private let isCompact: Bool

    /// `isCompact` caps the title's width and lets it scale down a little, so a long metric name still shares
    /// a row with the range control on a narrow phone.
    public init(title: String, systemImage: String, tint: Color, isCompact: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isCompact = isCompact
    }

    @ViewBuilder
    private var titleText: some View {
        let text = Text(verbatim: title)
            .font(StrandFont.captionNumber.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
        if isCompact {
            text.minimumScaleFactor(0.74).frame(maxWidth: 104, alignment: .leading)
        } else {
            text
        }
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            titleText
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .frame(minHeight: 44)
        .contentShape(Capsule(style: .continuous))
    }
}

/// The metric chip and the range control on one tight row, so the control row reads as part of the section it
/// drives. At larger text sizes, or when a long metric name leaves no room, the range control drops under the
/// chip instead of truncating. `leading` receives whether the chip should compress its title.
public struct TrendsControlRow<Leading: View, Trailing: View>: View {
    private let leading: (Bool) -> Leading
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(@ViewBuilder leading: @escaping (Bool) -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading
        self.trailing = trailing()
    }

    public var body: some View {
        if typeSize >= .xLarge {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                row(isCompact: false)
                row(isCompact: true)
                stacked
            }
        }
    }

    private func row(isCompact: Bool) -> some View {
        HStack(spacing: 0) {
            leading(isCompact)
            Spacer(minLength: NoopMetrics.space2)
            trailing
        }
        .frame(minHeight: 44)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            leading(false)
            trailing.frame(minHeight: 44)
        }
    }
}

/// A small action in the Today chip language (the "2H ›" / "Details ›" capsule), made public for screens that
/// live outside this package. With no title it is just a symbol.
public struct TrendsChip: View {
    private let title: LocalizedStringKey?
    private let systemImage: String?
    private let showsChevron: Bool

    public init(_ title: LocalizedStringKey? = nil, systemImage: String? = nil, showsChevron: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.showsChevron = showsChevron
    }

    public var body: some View {
        WidgetChip(title, systemImage: systemImage, showsChevron: showsChevron, overhangs: false)
    }
}

/// A chevron chip for stepping through weeks, with a 44pt touch target and a dimmed disabled state.
public struct TrendsStepChipLabel: View {
    private let systemImage: String
    private let isEnabled: Bool

    public init(systemImage: String, isEnabled: Bool = true) {
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }

    public var body: some View {
        WidgetChip(systemImage: systemImage, showsChevron: false, overhangs: false)
            .opacity(isEnabled ? 1 : 0.4)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Hero plot layout

/// The static layers of the hero plot, in the plot's own coordinates.
struct TrendsPlotLayout {
    let rendered: [CGPoint]
    let baselineY: CGFloat
    let zoneTop: CGFloat
    let zoneBottom: CGFloat
    let highY: CGFloat?
    let lowY: CGFloat?
    let railLabels: [(text: String, point: CGPoint)]
    let typicalSpot: CGPoint?
    let line: Path
    let area: Path
}

/// Remembers the last layout so a scrub, which redraws the plot on every step, does not rebuild it.
final class TrendsPlotLayoutCache {
    private struct Key: Equatable {
        let size: CGSize
        let token: Int
        let labelUnit: CGFloat
    }

    private var key: Key?
    private var stored: TrendsPlotLayout?

    func layout(size: CGSize, token: Int, labelUnit: CGFloat, make: () -> TrendsPlotLayout) -> TrendsPlotLayout {
        let wanted = Key(size: size, token: token, labelUnit: labelUnit)
        if let stored, key == wanted { return stored }
        let made = make()
        key = wanted
        stored = made
        return made
    }
}

// MARK: - Hero chart

/// The selected-range chart: a hero value with a baseline pill, then the Coach trend recipe (a tinted line over
/// a wash, a quiet typical band, a dashed average rule, knocked-out rail labels, four date labels). Touch and
/// drag reads any day: the hero value, its caption and the pill morph into that day's reading.
public struct TrendsHeroChart: View {
    private let days: [CalendarMetricDay]
    private let dateDomain: ClosedRange<Date>
    private let referenceDate: Date
    private let calendar: Calendar
    /// The calendar the dates are printed in (month names, years). Day counts always use `calendar`.
    private let displayCalendar: Calendar
    private let baseline: Double
    private let typical: ClosedRange<Double>
    private let tint: DomainTint
    private let colorsLineByBand: Bool
    private let unit: String
    let valueFormat: (Double) -> String
    private let direction: TrendPanelChart.Direction
    private let metricName: String
    /// The longest stretch between two readings the line still bridges. Three days for the daily default; a
    /// weekly or sparse series passes a limit that matches its own cadence so it still draws one connected line.
    private let gapLimitDays: Int
    /// Colour the change pill by the typical band instead of by the sign of the move: neutral while the value sits
    /// inside the band, the metric's good or bad colour only once it is outside it. False for every default chart.
    private let neutralInsideTypical: Bool
    /// At an accessibility text size, put the change pill under the value instead of beside it, so neither is
    /// squeezed onto a second line. False for every default chart.
    private let stacksPillAtAccessibilitySizes: Bool
    /// A window of a year or more, whose ticks fall in different months: axis and reading dates carry the year
    /// so two Octobers are never alike. False for every default (W/M/3M/6M) chart.
    private let showsYear: Bool

    let points: [TrendPoint]
    private let axis: TrendsAxis
    private let dayIndices: [Int]
    let tickLabels: [(label: String, fraction: Double)]
    /// Indices (into `points`) of days with no neighbour inside the gap limit: no line reaches them, so they
    /// always get their own dot.
    /// Points that stand alone between gaps: no line reaches them, so each is drawn as a dot at any range.
    let singletonIndices: Set<Int>
    private let summaryText: String
    /// Changes whenever anything that shapes the plot's static layers changes.
    private let layoutToken: Int

    @ScaledMetric(relativeTo: .caption2) private var scaledLabelUnit: CGFloat = 1
    /// Label offsets scale with the type at an accessibility size only; every smaller size keeps its points.
    private var labelUnit: CGFloat { typeSize.isAccessibilitySize ? scaledLabelUnit : 1 }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var revealed = false
    @State private var scrubDay: CalendarMetricDay?
    @State private var plotWidth: CGFloat = 1
    @State private var layoutCache = TrendsPlotLayoutCache()
    @State private var adjustReset: Task<Void, Never>?

    private static let plotHeight: CGFloat = 148

    public init(
        days: [CalendarMetricDay],
        dateDomain: ClosedRange<Date>,
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent,
        displayCalendar: Calendar? = nil,
        baseline: Double,
        typical: ClosedRange<Double>,
        tint: DomainTint,
        colorsLineByBand: Bool = false,
        unit: String,
        valueFormat: @escaping (Double) -> String = { ComponentValueFormat.rounded($0) },
        valueBounds: ClosedRange<Double> = (-Double.greatestFiniteMagnitude)...Double.greatestFiniteMagnitude,
        direction: TrendPanelChart.Direction = .contextual,
        metricName: String = "Trend",
        longRange: Bool = false,
        maxGapDays: Int = 3,
        neutralInsideTypical: Bool = false,
        stacksPillAtAccessibilitySizes: Bool = false
    ) {
        let sorted = days.sorted { $0.date < $1.date }
        self.days = sorted
        self.dateDomain = dateDomain
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.displayCalendar = displayCalendar ?? calendar
        self.baseline = baseline
        self.typical = typical
        self.tint = tint
        self.colorsLineByBand = colorsLineByBand
        self.unit = unit
        self.valueFormat = valueFormat
        self.direction = direction
        self.metricName = metricName
        self.gapLimitDays = max(maxGapDays, 1)
        self.neutralInsideTypical = neutralInsideTypical
        self.stacksPillAtAccessibilitySizes = stacksPillAtAccessibilitySizes

        var series: [TrendPoint] = []
        var indices: [Int] = []
        for (index, day) in sorted.enumerated() {
            guard let value = day.value, value.isFinite else { continue }
            series.append(TrendPoint(date: day.date, value: value))
            indices.append(index)
        }
        self.points = series
        self.dayIndices = indices
        self.axis = TrendsAxis.make(values: series.map(\.value), baseline: baseline, bounds: valueBounds)
        // A year or more reads as "Oct 2025 · Feb 2026 …". A short history under the same control (ALL on a
        // month of data) would repeat one month under every tick, so it falls back to day labels.
        var labels = Self.makeTickLabels(
            domain: dateDomain, referenceDate: referenceDate, calendar: calendar,
            displayCalendar: displayCalendar ?? calendar, template: longRange ? "MMM yyyy" : "MMM d")
        var yearLabels = longRange
        if longRange, Set(labels.map(\.label)).count < labels.count {
            labels = Self.makeTickLabels(
                domain: dateDomain, referenceDate: referenceDate, calendar: calendar,
                displayCalendar: displayCalendar ?? calendar, template: "MMM d")
            yearLabels = false
        }
        self.tickLabels = labels
        self.showsYear = yearLabels
        let runs = TrendCurve.runs(dayIndices: indices, maxGapDays: max(maxGapDays, 1))
        self.singletonIndices = Set(runs.filter { $0.count == 1 }.map(\.lowerBound))

        var hasher = Hasher()
        hasher.combine(series.count)
        for point in series {
            hasher.combine(point.date)
            hasher.combine(point.value)
        }
        hasher.combine(dateDomain.lowerBound)
        hasher.combine(dateDomain.upperBound)
        hasher.combine(baseline)
        hasher.combine(typical.lowerBound)
        hasher.combine(typical.upperBound)
        hasher.combine(colorsLineByBand)
        hasher.combine(unit)
        hasher.combine(max(maxGapDays, 1))
        self.layoutToken = hasher.finalize()

        let suffix = TrendsUnitSuffix.text(for: unit)
        let latestText = series.last.map { "\(valueFormat($0.value))\(suffix)" } ?? String(localized: "none")
        let averageText = "\(valueFormat(baseline))\(suffix)"
        let lowerText = valueFormat(typical.lowerBound)
        let upperText = valueFormat(typical.upperBound)
        let missing = sorted.filter { $0.value == nil }.count
        self.summaryText = String(
            localized: "\(metricName) trend, latest \(latestText), average \(averageText), typical \(lowerText) to \(upperText), \(series.count) recorded days and \(missing) missing.")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            heroRow
            VStack(alignment: .leading, spacing: 6) {
                plot.frame(height: Self.plotHeight)
                dateLabels
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.05)) {
                revealed = true
            }
        }
    }

    // MARK: Derived

    private var unitSuffix: String { TrendsUnitSuffix.text(for: unit) }

    private var lastValue: Double? { points.last?.value }

    private var shownValue: Double? {
        if let scrubDay { return scrubDay.value }
        return lastValue
    }

    private func color(for value: Double) -> Color {
        colorsLineByBand ? RecoveryBands.color(for: value) : tint.accent
    }

    /// The wash and band behind the line. Recovery's own colour changes with every band the line crosses, so
    /// its wash stays neutral rather than turning the whole plot yellow.
    private var washColor: Color {
        colorsLineByBand ? StrandPalette.textSecondary : tint.accent
    }

    // MARK: Hero

    private var heroRow: some View {
        Group {
            if stacksPillAtAccessibilitySizes && typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    heroValue
                    deltaPillView
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    heroValue
                    Spacer(minLength: NoopMetrics.space2)
                    deltaPillView
                }
            }
        }
        .animation(StrandMotion.fade, value: scrubDay)
    }

    private var heroValue: some View {
        HeroValue(
            value: shownValue.map(valueFormat) ?? WidgetMetrics.missingValue,
            unit: shownValue == nil || unit.isEmpty ? nil : unit,
            caption: heroCaption,
            captionPlacement: .below
        )
    }

    @ViewBuilder
    private var deltaPillView: some View {
        if let shownValue {
            let pill = deltaPill(for: shownValue)
            StatePill(pill.title, tone: pill.tone, showsDot: false)
                .accessibilityLabel(pill.spoken)
        }
    }

    private var heroCaption: String {
        if let scrubDay {
            let label = dayLabel(scrubDay.date)
            return scrubDay.value == nil ? String(localized: "No data · \(label)") : label
        }
        guard let latest = points.last else { return String(localized: "No data in this range") }
        if calendar.isDate(latest.date, inSameDayAs: dateDomain.upperBound) { return String(localized: "latest") }
        let label = dayLabel(latest.date)
        return String(localized: "latest · \(label)")
    }

    /// The change against the range average: the pill's title, what VoiceOver says instead of the arrow glyph,
    /// and the tone (green when the move is the good direction for the metric, red when it is not).
    private func deltaPill(for value: Double) -> (title: LocalizedStringKey, spoken: String, tone: StrandTone) {
        let delta = value - baseline
        let magnitude = valueFormat(abs(delta))
        guard delta.isFinite, !trendsFormattedIsZero(magnitude) else {
            return ("On average", String(localized: "On average"), .neutral)
        }
        let tone = Self.deltaTone(
            value: value, baseline: baseline, typical: typical, direction: direction,
            neutralInsideTypical: neutralInsideTypical)
        if delta > 0 {
            return ("▲ \(magnitude) vs avg", String(localized: "up \(magnitude) vs avg"), tone)
        }
        return ("▼ \(magnitude) vs avg", String(localized: "down \(magnitude) vs avg"), tone)
    }

    /// The pill's tone. By default the sign of the move against the range average decides it: green when it is the
    /// good direction for the metric, red when it is not. With `neutralInsideTypical` a value inside the typical band
    /// stays neutral (an ordinary day is not a warning), and only a value outside the band takes the good or bad
    /// colour for the side it fell on. A metric with no good direction is always neutral.
    static func deltaTone(
        value: Double,
        baseline: Double,
        typical: ClosedRange<Double>,
        direction: TrendPanelChart.Direction,
        neutralInsideTypical: Bool
    ) -> StrandTone {
        if neutralInsideTypical {
            guard !typical.contains(value) else { return .neutral }
            let above = value > typical.upperBound
            switch direction {
            case .higherIsBetter: return above ? .positive : .critical
            case .lowerIsBetter: return above ? .critical : .positive
            case .contextual: return .neutral
            }
        }
        let delta = value - baseline
        switch direction {
        case .higherIsBetter: return delta > 0 ? .positive : .critical
        case .lowerIsBetter: return delta < 0 ? .positive : .critical
        case .contextual: return .neutral
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            plotLayers(size: proxy.size)
                .contentShape(Rectangle())
                .trendsScrub(onScrub: { scrub(at: $0) }, onEnd: { endScrub() })
                .onAppear { plotWidth = proxy.size.width }
                .onChangeCompat(of: proxy.size.width) { plotWidth = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryText)
        .accessibilityValue(selectedDayAccessibilityValue)
        .accessibilityHint(Text("Swipe up or down to step through days"))
        .accessibilityAdjustableAction { direction in
            guard !days.isEmpty else { return }
            let current = scrubDay.flatMap { selected in
                days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: selected.date) })
            } ?? max(days.count - 1, 0)
            switch direction {
            case .increment: scrubDay = days[min(current + 1, days.count - 1)]
            case .decrement: scrubDay = days[max(current - 1, 0)]
            default: break
            }
            scheduleAdjustReset()
        }
        .onDisappear { adjustReset?.cancel() }
    }

    /// VoiceOver has no "adjust ended" callback, so the stepped reading clears itself a few seconds after the last
    /// step, and the hero goes back to the latest day.
    private func scheduleAdjustReset() {
        adjustReset?.cancel()
        adjustReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(StrandMotion.interactive) { scrubDay = nil }
        }
    }

    /// Everything in the plot that depends only on the data and the plot's size: the curve, its wash, the rails
    /// and where each label sits. Built once per data or size change, not on every scrub step.
    private func makeLayout(size: CGSize) -> TrendsPlotLayout {
        let yOf: (Double) -> CGFloat = { size.height * CGFloat(1 - axis.unit($0)) }
        let rendered: [CGPoint] = points.map {
            CGPoint(x: size.width * CGFloat(TrendCalendar.unitPosition(of: $0.date, in: dateDomain)), y: yOf($0.value))
        }
        let baselineY = yOf(baseline)
        let zoneTop = yOf(min(typical.upperBound, axis.upper))
        let zoneBottom = yOf(max(typical.lowerBound, axis.lower))

        let high = points.map(\.value).max()
        let low = points.map(\.value).min()
        let highY = high.map(yOf)
        let lowY = low.map(yOf)
        let showsLow = (lowY ?? 0) - (highY ?? 0) > 16
        let showsAverageLabel = [highY, showsLow ? lowY : nil]
            .compactMap { $0 }
            .allSatisfy { abs($0 - baselineY) > 14 }
        // Labels slide along their rule to the clearest slot, away from where the line crosses.
        let samples = lineSamples(rendered)
        let railLabels = railLabelPlacements(
            high: high, highY: highY, low: showsLow ? low : nil, lowY: lowY,
            baselineY: showsAverageLabel ? baselineY : nil, width: size.width, samples: samples
        )
        let typicalSpot: CGPoint? = zoneBottom > zoneTop
            ? typicalLabelSpot(
                zoneTop: zoneTop, zoneBottom: zoneBottom, width: size.width, samples: samples,
                avoiding: railLabels.map(\.point)
            )
            : nil
        return TrendsPlotLayout(
            rendered: rendered,
            baselineY: baselineY,
            zoneTop: zoneTop,
            zoneBottom: zoneBottom,
            highY: highY,
            lowY: showsLow ? lowY : nil,
            railLabels: railLabels,
            typicalSpot: typicalSpot,
            line: linePath(rendered),
            area: areaPath(rendered, height: size.height)
        )
    }

    @ViewBuilder
    private func plotLayers(size: CGSize) -> some View {
        let xOf: (Date) -> CGFloat = { size.width * CGFloat(TrendCalendar.unitPosition(of: $0, in: dateDomain)) }
        let yOf: (Double) -> CGFloat = { size.height * CGFloat(1 - axis.unit($0)) }
        let layout = layoutCache.layout(size: size, token: layoutToken, labelUnit: labelUnit) {
            makeLayout(size: size)
        }
        let rendered = layout.rendered
        let baselineY = layout.baselineY
        let zoneTop = layout.zoneTop
        let zoneBottom = layout.zoneBottom
        let highY = layout.highY
        let lowY = layout.lowY
        let railLabels = layout.railLabels
        let typicalSpot = layout.typicalSpot
        let line = layout.line
        let area = layout.area
        let dotIndices = points.indices.filter { points.count <= 35 || singletonIndices.contains($0) }

        ZStack {
            // The typical zone: a quiet band; its name is placed with the other labels below the line.
            if zoneBottom > zoneTop {
                Rectangle()
                    .fill(washColor.opacity(colorsLineByBand ? 0.05 : 0.07))
                    .frame(height: zoneBottom - zoneTop)
                    .position(x: size.width / 2, y: (zoneTop + zoneBottom) / 2)
            }

            // Rails at the recorded high and low, and the dashed average between them.
            if let highY { rail(y: highY, width: size.width, dashed: false) }
            if let lowY { rail(y: lowY, width: size.width, dashed: false) }
            rail(y: baselineY, width: size.width, dashed: true)

            if rendered.count >= 2 {
                area
                    .fill(LinearGradient(colors: [washColor.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                    .opacity(revealed ? 1 : 0)
                line
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(lineGradient, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            // One dot per recorded day while the series is short enough to read them, and always one for a day
            // the line cannot reach.
            ForEach(dotIndices, id: \.self) { index in
                Circle()
                    .fill(color(for: points[index].value))
                    .frame(width: 4, height: 4)
                    .position(rendered[index])
                    .opacity(revealed ? 1 : 0)
            }

            if revealed, scrubDay == nil, let end = rendered.last {
                Circle()
                    .fill(color(for: points[points.count - 1].value))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
                    .transition(.opacity)
            }

            // Names ride above the line on a canvas plate, each on the clearest stretch of its rule. At the accessibility
            // sizes they would be three times the size of a 148 pt plot's rules and land on each other and on the line;
            // the stat row under the chart carries the low, average and high there, and the reading above it the rest.
            if let typicalSpot, !typeSize.isAccessibilitySize {
                Text("typical")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .trendsRailKnockout()
                    .fixedSize()
                    .position(typicalSpot)
            }
            ForEach(Array((typeSize.isAccessibilitySize ? [] : railLabels).enumerated()), id: \.offset) { _, label in
                Text(verbatim: label.text)
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .trendsRailKnockout()
                    .fixedSize()
                    .position(label.point)
            }

            if let scrubDay {
                let scrubX = xOf(scrubDay.date)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: scrubX, y: size.height / 2)
                if let value = scrubDay.value {
                    Circle()
                        .fill(color(for: value))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                        .position(x: scrubX, y: yOf(value))
                }
            }
        }
    }

    private static let railLabelInset: CGFloat = 16

    /// The line, sampled every few points along every run, for keeping labels off it.
    private func lineSamples(_ rendered: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for run in TrendCurve.runs(dayIndices: dayIndices, maxGapDays: gapLimitDays) where !run.isEmpty {
            let slice = Array(rendered[run])
            out.append(contentsOf: slice)
            for pair in zip(slice, slice.dropFirst()) {
                let steps = max(1, Int(hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y) / 4))
                for step in 1..<max(steps, 2) {
                    let t = CGFloat(step) / CGFloat(steps)
                    out.append(CGPoint(x: pair.0.x + (pair.1.x - pair.0.x) * t, y: pair.0.y + (pair.1.y - pair.0.y) * t))
                }
            }
        }
        return out
    }

    private func railLabelPlacements(
        high: Double?, highY: CGFloat?, low: Double?, lowY: CGFloat?, baselineY: CGFloat?,
        width: CGFloat, samples: [CGPoint]
    ) -> [(text: String, point: CGPoint)] {
        var placed: [(text: String, point: CGPoint)] = []
        func place(_ text: String, y: CGFloat) {
            if let x = labelSlot(at: y, text: text, width: width, samples: samples) {
                placed.append((text, CGPoint(x: x, y: y)))
            }
        }
        if let high, let highY { place(valueFormat(high), y: highY) }
        if let low, let lowY { place(valueFormat(low), y: lowY) }
        if let baselineY { place(String(localized: "avg \(valueFormat(baseline))"), y: baselineY) }
        return placed
    }

    /// Half the width of a label's plate, scaled with the text size.
    private func halfWidth(of text: String) -> CGFloat {
        max(14, CGFloat(text.count) * 2.9 + 6) * labelUnit
    }

    /// How many sampled points of the line fall inside a label box centred on `point`.
    private func crossings(of point: CGPoint, halfWidth: CGFloat, samples: [CGPoint]) -> Int {
        samples.reduce(0) { count, sample in
            abs(sample.x - point.x) <= halfWidth + 3 && abs(sample.y - point.y) <= 10 * labelUnit ? count + 1 : count
        }
    }

    /// The centre x of the slot on a rule at `y` where the line crosses the label least, searching from the
    /// trailing edge inwards so the first clear stretch wins.
    private func labelSlot(at y: CGFloat, text: String, width: CGFloat, samples: [CGPoint]) -> CGFloat? {
        let half = halfWidth(of: text)
        var best: (x: CGFloat, hits: Int)?
        for index in 0..<10 {
            let x = width - Self.railLabelInset - half - CGFloat(index) * 40 * labelUnit
            guard x - half >= 0 else { break }
            let hits = crossings(of: CGPoint(x: x, y: y), halfWidth: half, samples: samples)
            if best == nil || hits < best!.hits { best = (x, hits) }
            if hits == 0 { break }
        }
        return best?.x
    }

    /// Where "typical" sits inside the band: the leading-most spot, from the top of the band down, that the
    /// line crosses least.
    private func typicalLabelSpot(
        zoneTop: CGFloat, zoneBottom: CGFloat, width: CGFloat, samples: [CGPoint], avoiding labels: [CGPoint]
    ) -> CGPoint? {
        let half = halfWidth(of: String(localized: "typical"))
        let inset = 10 * labelUnit
        let ys = [zoneTop + inset, (zoneTop + zoneBottom) / 2, zoneBottom - inset]
            .filter { $0 >= 8 && $0 <= zoneBottom }
        var best: (point: CGPoint, hits: Int)?
        for y in ys {
            for index in 0..<10 {
                let x = half + 4 + CGFloat(index) * 36 * labelUnit
                guard x + half <= width else { break }
                let point = CGPoint(x: x, y: y)
                let overlapsLabel = labels.contains { abs($0.x - point.x) < 62 * labelUnit && abs($0.y - point.y) < 18 * labelUnit }
                let hits = crossings(of: point, halfWidth: half, samples: samples) + (overlapsLabel ? 1000 : 0)
                if best == nil || hits < best!.hits { best = (point, hits) }
                if hits == 0 { return point }
            }
        }
        return best?.point
    }

    @ViewBuilder
    private func rail(y: CGFloat, width: CGFloat, dashed: Bool) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(
            dashed ? StrandPalette.hairlineStrong.opacity(0.9) : StrandPalette.hairline.opacity(0.9),
            style: StrokeStyle(lineWidth: 0.7, dash: dashed ? [3, 4] : [])
        )
    }

    private var lineGradient: LinearGradient {
        if colorsLineByBand {
            return LinearGradient(stops: bandStops, startPoint: .bottom, endPoint: .top)
        }
        return LinearGradient(
            colors: [tint.accent.opacity(0.55), tint.accent], startPoint: .bottom, endPoint: .top)
    }

    /// Hard recovery-band boundaries projected onto the visible range, so the line changes colour exactly where
    /// it crosses into the next band (the raw cut points: a raw 33.5 is the first score drawn "34"). Each side of
    /// an edge takes its colour from the band itself, not from probing a hair below the cut, which rounding blurs.
    private var bandStops: [Gradient.Stop] {
        var stops: [Gradient.Stop] = [.init(color: RecoveryBands.color(for: axis.lower), location: 0)]
        let bands: [RecoveryBand] = [.low, .medium, .high]
        for (index, cut) in RecoveryBands.rawCutPoints.enumerated() {
            let position = axis.unit(cut)
            guard position > 0.001, position < 0.999 else { continue }
            stops.append(.init(color: RecoveryBands.color(of: bands[index]), location: max(0, position - 0.0005)))
            stops.append(.init(color: RecoveryBands.color(of: bands[index + 1]), location: position))
        }
        stops.append(.init(color: RecoveryBands.color(for: axis.upper), location: 1))
        return stops
    }

    private func linePath(_ rendered: [CGPoint]) -> Path {
        var path = Path()
        for run in TrendCurve.runs(dayIndices: dayIndices, maxGapDays: gapLimitDays) where run.count >= 2 {
            TrendCurve.append(Array(rendered[run]), to: &path)
        }
        return path
    }

    private func areaPath(_ rendered: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        for run in TrendCurve.runs(dayIndices: dayIndices, maxGapDays: gapLimitDays) where run.count >= 2 {
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

    private func scrub(at location: CGPoint) {
        guard plotWidth > 0, !days.isEmpty else { return }
        let fraction = min(max(Double(location.x / plotWidth), 0), 1)
        guard let day = TrendCalendar.day(atUnitPosition: fraction, in: days), day != scrubDay else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrubDay = day }
        StrandHaptic.selection.play()
    }

    private func endScrub() {
        guard scrubDay != nil else { return }
        withAnimation(StrandMotion.interactive) { scrubDay = nil }
    }

    // MARK: Date labels

    /// The labels drawn: all of them, or at the accessibility sizes only the first and last, which are what fit side by
    /// side at that size.
    private var shownTickLabels: [(index: Int, tick: (label: String, fraction: Double))] {
        let all = Array(tickLabels.enumerated()).map { (index: $0.offset, tick: $0.element) }
        guard typeSize.isAccessibilitySize, all.count > 2, let first = all.first, let last = all.last else { return all }
        return [first, last]
    }

    private var dateLabels: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(shownTickLabels, id: \.index) { item in
                    Text(verbatim: item.tick.label)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .frame(width: 0, alignment: alignment(for: item.index, of: tickLabels.count))
                        .offset(x: proxy.size.width * item.tick.fraction)
                }
            }
        }
        .frame(height: 16 * labelUnit)
        .accessibilityHidden(true)
    }

    private func alignment(for index: Int, of count: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == count - 1 { return .trailing }
        return .center
    }

    /// At most four labels, evenly spaced from the first day to the last, snapped to whole days so each sits
    /// exactly under its own day. The last reads "Today" when the range ends today.
    private static func makeTickLabels(
        domain: ClosedRange<Date>,
        referenceDate: Date,
        calendar: Calendar,
        displayCalendar: Calendar,
        template: String
    ) -> [(label: String, fraction: Double)] {
        let totalDays = TrendCalendar.dayCount(from: domain.lowerBound, to: domain.upperBound, calendar: calendar)
        guard totalDays > 0 else {
            return [(TrendCalendar.relativeLabel(
                for: domain.upperBound, relativeTo: referenceDate, calendar: calendar, displayCalendar: displayCalendar), 0)]
        }
        let count = min(WidgetMetrics.maxXAxisLabels, totalDays + 1)
        var seen = Set<Int>()
        var labels: [(label: String, fraction: Double)] = []
        for index in 0..<count {
            let dayIndex = Int((Double(totalDays) * Double(index) / Double(max(count - 1, 1))).rounded())
            guard seen.insert(dayIndex).inserted,
                  let date = TrendCalendar.startOfDay(addingDays: dayIndex, to: domain.lowerBound, calendar: calendar) else { continue }
            let isLast = dayIndex == totalDays
            let label = isLast
                ? TrendCalendar.relativeLabel(for: date, relativeTo: referenceDate, calendar: calendar, displayCalendar: displayCalendar)
                : TrendsDateFormatters.shared.string(from: date, template: template, calendar: displayCalendar)
            labels.append((label, Double(dayIndex) / Double(totalDays)))
        }
        return labels
    }

    // MARK: Accessibility

    private var selectedDayAccessibilityValue: String {
        guard let day = scrubDay ?? days.last else { return String(localized: "No trend data") }
        let value = day.value.map { "\(valueFormat($0))\(unitSuffix)" } ?? String(localized: "No data")
        return "\(dayLabel(day.date)), \(value)"
    }

    /// Today, Yesterday, else the date in the person's calendar: with the year when the window spans a year or more.
    /// `internal` so the tests can read the caption and the spoken day without a view.
    func dayLabel(_ date: Date) -> String {
        let relative = TrendCalendar.relativeLabel(
            for: date, relativeTo: referenceDate, calendar: calendar, displayCalendar: displayCalendar)
        guard showsYear, !calendar.isDate(date, inSameDayAs: referenceDate),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate),
              !calendar.isDate(date, inSameDayAs: yesterday) else { return relative }
        return TrendsDateFormatters.shared.string(from: date, template: "EEE MMM d yyyy", calendar: displayCalendar)
    }
}

// MARK: - Calendar heat

/// The last five Monday-first weeks as square, 6pt-radius tiles at 70% of their column, so the grid keeps generous
/// negative space. Recovery draws its three band hues at full strength; every other metric steps the opacity of its
/// own tint. Today is outlined, days with no reading are faint outlines, and touching and holding then dragging across
/// the grid reads any day.
public struct TrendsCalendarHeat: View {
    private let days: [TrendCalendarDay]
    private let tint: DomainTint
    private let referenceDate: Date
    private let calendar: Calendar
    let valueFormat: (Double) -> String
    private let colorScale: TrendHeatColorScale

    private let weekdayInitials: [String]
    private let summaryText: String
    /// Where VoiceOver starts stepping: today's tile, else the last day with a reading.
    private let startIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var scrubIndex: Int?
    @State private var adjustReset: Task<Void, Never>?

    private static let columns = 7
    private static let intensitySteps: [Double] = [0.18, 0.34, 0.5, 0.66, 0.82]

    /// Cell geometry for a grid `width` points wide: square tiles at 70% of their column on a square pitch, so
    /// the grid keeps generous negative space.
    private struct Geometry {
        let column: CGFloat
        let side: CGFloat
    }

    private func geometry(width: CGFloat) -> Geometry {
        let column = width / CGFloat(Self.columns)
        return Geometry(column: column, side: max(10, column * 0.7))
    }

    public init(
        days: [TrendCalendarDay],
        tint: DomainTint,
        referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        valueFormat: @escaping (Double) -> String = { ComponentValueFormat.rounded($0) },
        colorScale: TrendHeatColorScale = .intensity
    ) {
        self.days = days
        self.tint = tint
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.valueFormat = valueFormat
        self.colorScale = colorScale
        self.weekdayInitials = TrendsWeekdayNames.veryShort(calendar: calendar)
        self.startIndex = days.firstIndex { calendar.isDate($0.date, inSameDayAs: referenceDate) }
            ?? days.lastIndex { $0.value != nil }
            ?? max(days.count - 1, 0)

        let values = days.compactMap(\.value)
        if let best = values.max() {
            let average = valueFormat(TrendCalendar.stableMean(values) ?? 0)
            let states = days.map { TrendCalendar.cellState(for: $0, today: referenceDate, calendar: calendar) }
            let missing = states.filter { $0 == .missing }.count
            let future = states.filter { $0 == .future }.count
            self.summaryText = String(
                localized: "Calendar, last 5 weeks, \(values.count) scored, \(missing) missing, \(future) upcoming, average \(average), best \(valueFormat(best)).")
        } else {
            self.summaryText = String(localized: "No calendar data yet.")
        }
    }

    private var rows: Int { max(Int((Double(days.count) / Double(Self.columns)).rounded(.up)), 1) }

    private var scoredRange: ClosedRange<Double> {
        let values = days.compactMap(\.value).filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        return low...high
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: 0) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, label in
                    Text(verbatim: label)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            grid
            footer
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryText)
        .accessibilityValue(selectedAccessibilityValue)
        .accessibilityAdjustableAction { direction in
            let current = scrubIndex ?? startIndex
            switch direction {
            case .increment: scrubIndex = min(current + 1, max(days.count - 1, 0))
            case .decrement: scrubIndex = max(current - 1, 0)
            default: break
            }
            scheduleAdjustReset()
        }
        .onDisappear { adjustReset?.cancel() }
    }

    /// VoiceOver has no "adjust ended" callback, so the stepped reading clears a few seconds after the last step.
    private func scheduleAdjustReset() {
        adjustReset?.cancel()
        adjustReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(StrandMotion.interactive) { scrubIndex = nil }
        }
    }

    // MARK: Grid

    private var grid: some View {
        let range = scoredRange
        let today = calendar.startOfDay(for: referenceDate)
        return GeometryReader { proxy in
            let geo = geometry(width: proxy.size.width)
            let columnWidth = geo.column
            ZStack(alignment: .topLeading) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let column = index % Self.columns
                    let row = index / Self.columns
                    cell(day: day, index: index, range: range, today: today)
                        .frame(width: geo.side, height: geo.side)
                        .position(
                            x: (CGFloat(column) + 0.5) * columnWidth,
                            y: CGFloat(row) * columnWidth + geo.side / 2
                        )
                        .opacity(revealed ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : StrandMotion.fade.delay(Double(index) * 0.008),
                            value: revealed
                        )
                }
                if let scrubIndex, days.indices.contains(scrubIndex) {
                    let column = scrubIndex % Self.columns
                    let row = scrubIndex / Self.columns
                    let anchor = CGPoint(
                        x: (CGFloat(column) + 0.5) * columnWidth,
                        y: CGFloat(row) * columnWidth + geo.side / 2
                    )
                    let day = days[scrubIndex]
                    ChartTooltip(
                        value: day.value.map(valueFormat) ?? String(localized: "No data"),
                        label: TrendCalendar.relativeLabel(for: day.date, relativeTo: referenceDate, calendar: calendar),
                        accent: day.value.map { colorScale == .recoveryBands ? RecoveryBands.color(for: $0) : tint.accent }
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
            .trendsScrub(
                onScrub: { location in
                    guard proxy.size.width > 0 else { return }
                    let index = cellIndex(at: location, columnWidth: columnWidth)
                    guard index != scrubIndex else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrubIndex = index }
                    StrandHaptic.selection.play()
                },
                onEnd: {
                    guard scrubIndex != nil else { return }
                    withAnimation(StrandMotion.interactive) { scrubIndex = nil }
                }
            )
        }
        // As tall as its square slots, less the gap under the last row.
        .aspectRatio(CGFloat(Self.columns) / (CGFloat(rows) - 0.3), contentMode: .fit)
    }

    private func cellIndex(at location: CGPoint, columnWidth: CGFloat) -> Int? {
        guard columnWidth > 0, !days.isEmpty else { return nil }
        let column = min(max(Int(location.x / columnWidth), 0), Self.columns - 1)
        let row = min(max(Int(location.y / columnWidth), 0), rows - 1)
        let index = row * Self.columns + column
        return index < days.count ? index : nil
    }

    @ViewBuilder
    private func cell(day: TrendCalendarDay, index: Int, range: ClosedRange<Double>, today: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let isToday = calendar.isDate(today, inSameDayAs: day.date)
        let isScrubbed = scrubIndex == index
        ZStack {
            switch TrendCalendar.cellState(for: day, today: referenceDate, calendar: calendar) {
            case .value(let value):
                shape.fill(fill(for: value, range: range))
            case .missing:
                shape.strokeBorder(StrandPalette.hairlineStrong.opacity(0.7), lineWidth: 1)
            case .future:
                shape.strokeBorder(StrandPalette.hairline.opacity(0.7), lineWidth: 1)
            }
            if isToday || isScrubbed {
                shape
                    .strokeBorder(StrandPalette.textPrimary.opacity(isScrubbed ? 0.95 : 0.7), lineWidth: 1.5)
                    .padding(-3)
            }
        }
    }

    private func fill(for value: Double, range: ClosedRange<Double>) -> Color {
        switch colorScale {
        case .recoveryBands:
            return RecoveryBands.color(for: value)
        case .intensity:
            let span = range.upperBound - range.lowerBound
            let unit = span > 0 ? (value - range.lowerBound) / span : 0.5
            let step = min(Self.intensitySteps.count - 1, max(0, Int(unit * Double(Self.intensitySteps.count))))
            return tint.accent.opacity(Self.intensitySteps[step])
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let scrubIndex, days.indices.contains(scrubIndex) {
            let day = days[scrubIndex]
            Text(verbatim: "\(TrendCalendar.relativeLabel(for: day.date, relativeTo: referenceDate, calendar: calendar)) · \(day.value.map(valueFormat) ?? String(localized: "No data"))")
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(day.value == nil ? StrandPalette.textTertiary : tint.accent)
                .frame(height: 14, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NoopMetrics.space3) {
                    legend
                    Spacer(minLength: NoopMetrics.space2)
                    bestLabel
                }
                legend
            }
            .frame(minHeight: 14)
        }
    }

    @ViewBuilder
    private var bestLabel: some View {
        if let best = TrendCalendar.best(in: days, relativeTo: referenceDate, calendar: calendar) {
            Text(verbatim: best.daysAgo == 0
                ? String(localized: "Best \(valueFormat(best.value)) · today")
                : String(localized: "Best \(valueFormat(best.value)) · \(best.daysAgo)d ago"))
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space3) {
            switch colorScale {
            case .recoveryBands:
                legendItem("Low", color: RecoveryBands.color(for: 10))
                legendItem("Moderate", color: RecoveryBands.color(for: 50))
                legendItem("Primed", color: RecoveryBands.color(for: 90))
            case .intensity:
                HStack(spacing: 4) {
                    Text("Lower").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    ForEach(Array(Self.intensitySteps.enumerated()), id: \.offset) { _, step in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(tint.accent.opacity(step))
                            .frame(width: 10, height: 8)
                    }
                    Text("Higher").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong.opacity(0.9), lineWidth: 1)
                    .frame(width: 8, height: 8)
                Text("No data").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func legendItem(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Accessibility

    private var selectedAccessibilityValue: String {
        guard let index = scrubIndex, days.indices.contains(index) else { return String(localized: "No day selected") }
        let day = days[index]
        return "\(TrendCalendar.relativeLabel(for: day.date, relativeTo: referenceDate, calendar: calendar)), \(day.value.map(valueFormat) ?? String(localized: "No data"))"
    }
}

// MARK: - Weekday bars

/// Seven Monday-first averages as slim rounded bars in the metric's tint, with a dashed average rule and the
/// current weekday lifted. Touch and drag reads any weekday.
public struct TrendsWeekdayBars: View {
    private let values: [Double?]
    private let tint: DomainTint
    private let referenceDate: Date
    private let calendar: Calendar
    private let barColor: ((Double) -> Color)?
    let valueFormat: (Double) -> String

    private let initials: [String]
    private let fullNames: [String]
    private let summaryText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var scrubIndex: Int?
    @State private var adjustReset: Task<Void, Never>?

    public init(
        values: [Double?],
        tint: DomainTint,
        referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        barColor: ((Double) -> Color)? = nil,
        valueFormat: @escaping (Double) -> String = { ComponentValueFormat.rounded($0) }
    ) {
        self.values = Array(values.prefix(7)) + Array(repeating: nil, count: max(0, 7 - values.count))
        self.tint = tint
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.barColor = barColor
        self.valueFormat = valueFormat
        let names = TrendsWeekdayNames.full(calendar: calendar)
        self.initials = TrendsWeekdayNames.veryShort(calendar: calendar)
        self.fullNames = names

        let current = TrendCalendar.mondayFirstWeekdayIndex(for: referenceDate, calendar: calendar)
        let padded = Array(values.prefix(7)) + Array(repeating: nil, count: max(0, 7 - values.count))
        let missingText = String(localized: "missing")
        let summary = zip(names, padded).map { name, value in
            "\(name) \(value.map(valueFormat) ?? missingText)"
        }.joined(separator: ", ")
        let today = names.indices.contains(current) ? names[current] : ""
        self.summaryText = String(
            localized: "Average by weekday. Today is \(today). \(summary). Touch and hold, then drag to inspect each weekday.")
    }

    public var body: some View {
        GeometryReader { proxy in
            let slot = proxy.size.width / 7
            let barWidth = min(max(8, slot * 0.36), 24)
            let scored = values.compactMap { $0 }
            let scale = FiniteChartScale(values: scored) ?? FiniteChartScale(values: [0, 1])!
            let average = TrendCalendar.stableMean(scored) ?? 0
            let currentWeekday = TrendCalendar.mondayFirstWeekdayIndex(for: referenceDate, calendar: calendar)
            let top: CGFloat = 10
            let plotHeight = max(54, proxy.size.height - 30)
            let heightOf: (Double) -> CGFloat = { value in
                max(6, CGFloat(0.25 + 0.75 * (scale.normalized(value) ?? 0.5)) * plotHeight)
            }
            let averageY = top + plotHeight - heightOf(average)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: averageY))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: averageY))
                }
                .stroke(StrandPalette.hairlineStrong.opacity(0.9), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))

                ForEach(0..<7, id: \.self) { index in
                    let value = values[index]
                    let height = value.map(heightOf) ?? 6
                    let x = slot * CGFloat(index) + slot / 2
                    let isSelected = scrubIndex == index
                    let isCurrent = index == currentWeekday
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(barFill(value: value, isCurrent: isCurrent, isSelected: isSelected))
                        .frame(width: barWidth, height: revealed ? height : 6)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(StrandPalette.textPrimary.opacity(0.9), lineWidth: 1.5)
                            }
                        }
                        .position(x: x, y: top + plotHeight - (revealed ? height : 6) / 2)
                        .animation(
                            reduceMotion ? nil : StrandMotion.value.delay(Double(index) * 0.03),
                            value: revealed
                        )
                    Text(verbatim: initials[index])
                        .font(StrandFont.micro.weight(isSelected || isCurrent ? .semibold : .regular))
                        .foregroundStyle(isSelected || isCurrent ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .position(x: x, y: top + plotHeight + 12)
                }

                // The average's name rests above its rule over the first weekday whose bar stays below it.
                if scrubIndex == nil, let labelIndex = (0..<7).first(where: { index in
                    values[index].map { heightOf($0) <= heightOf(average) } ?? true
                }) {
                    let averageText = String(localized: "avg \(valueFormat(average))")
                    // Keep the plate inside the row however wide the text and the average are.
                    let half = max(14, CGFloat(averageText.count) * 2.9 + 6)
                    Text(verbatim: averageText)
                        .font(StrandFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .trendsRailKnockout()
                        .fixedSize()
                        .position(
                            x: min(max(half, slot * CGFloat(labelIndex) + slot / 2), max(half, proxy.size.width - half)),
                            y: max(7, averageY - 9)
                        )
                }

                if let scrubIndex, values.indices.contains(scrubIndex) {
                    let value = values[scrubIndex]
                    let height = value.map(heightOf) ?? 6
                    let x = slot * CGFloat(scrubIndex) + slot / 2
                    ChartTooltip(
                        value: value.map(valueFormat) ?? String(localized: "No data"),
                        label: fullNames[scrubIndex],
                        accent: value.map { barColor?($0) ?? tint.accent }
                    )
                    .position(
                        ChartTooltipPlacement.position(
                            anchor: CGPoint(x: x, y: top + plotHeight - height),
                            tooltipSize: CGSize(width: 104, height: 40),
                            in: proxy.size
                        )
                    )
                }
            }
            .contentShape(Rectangle())
            .trendsScrub(
                onScrub: { location in
                    guard proxy.size.width > 0 else { return }
                    let index = TrendCalendar.weekdayIndex(atUnitPosition: Double(location.x / proxy.size.width))
                    guard index != scrubIndex else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrubIndex = index }
                    StrandHaptic.selection.play()
                },
                onEnd: {
                    guard scrubIndex != nil else { return }
                    withAnimation(StrandMotion.interactive) { scrubIndex = nil }
                }
            )
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryText)
        .accessibilityValue(selectedWeekdayAccessibilityValue)
        .accessibilityAdjustableAction { direction in
            let current = scrubIndex ?? TrendCalendar.mondayFirstWeekdayIndex(for: referenceDate, calendar: calendar)
            switch direction {
            case .increment: scrubIndex = min(current + 1, 6)
            case .decrement: scrubIndex = max(current - 1, 0)
            default: break
            }
            scheduleAdjustReset()
        }
        .onDisappear { adjustReset?.cancel() }
    }

    /// VoiceOver has no "adjust ended" callback, so the stepped reading clears a few seconds after the last step.
    private func scheduleAdjustReset() {
        adjustReset?.cancel()
        adjustReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(StrandMotion.interactive) { scrubIndex = nil }
        }
    }

    private func barFill(value: Double?, isCurrent: Bool, isSelected: Bool) -> Color {
        guard let value else {
            return isSelected || isCurrent ? StrandPalette.textPrimary.opacity(0.16) : StrandPalette.surfaceInset
        }
        let base = barColor?(value) ?? tint.accent
        if isSelected { return base }
        return base.opacity(isCurrent ? 1 : 0.72)
    }

    private var selectedWeekdayAccessibilityValue: String {
        guard let index = scrubIndex else { return String(localized: "No weekday selected") }
        return "\(fullNames[index]), \(values[index].map(valueFormat) ?? String(localized: "No data"))"
    }
}

// MARK: - Summary row

/// One score's compact read: its symbol in the domain colour, its name over the change against the prior
/// period, a range-wide sparkline and the latest value.
public struct TrendsSummaryRow: View {
    private let systemImage: String
    private let label: String
    private let values: [Double]
    private let latest: String
    private let delta: String
    private let tone: TrendDeltaTone
    private let tint: DomainTint

    public init(
        systemImage: String,
        label: String,
        values: [Double],
        latest: String,
        delta: String,
        tone: TrendDeltaTone,
        tint: DomainTint
    ) {
        self.systemImage = systemImage
        self.label = label
        self.values = values
        self.latest = latest
        self.delta = delta
        self.tone = tone
        self.tint = tint
    }

    private var deltaColor: Color {
        switch tone {
        case .positive: StrandPalette.statusPositive
        case .negative: StrandPalette.statusCritical
        case .neutral: StrandPalette.textTertiary
        }
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: systemImage)
                .font(StrandFont.caption)
                .foregroundStyle(tint.accent)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                Text(verbatim: delta)
                    .font(StrandFont.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: NoopMetrics.space2)
            sparkline
                .frame(width: 72, height: 24)
                .accessibilityHidden(true)
            Text(verbatim: latest)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(latest == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(latest), \(delta)")
    }

    @ViewBuilder
    private var sparkline: some View {
        if values.count > 1 {
            Sparkline(
                values: values,
                gradient: Gradient(colors: [tint.accent.opacity(0.62), tint.accent]),
                lineWidth: 2,
                showsArea: true,
                showsHead: true,
                showsHover: false
            )
        } else {
            ZStack {
                Capsule(style: .continuous).fill(StrandPalette.surfaceInset).frame(height: 2)
                if !values.isEmpty { Circle().fill(tint.accent).frame(width: 6, height: 6) }
            }
        }
    }
}

// MARK: - Training load chart

/// Acute and chronic load as two lines on one scale: the 42-day line is the quiet backdrop, the 7-day line
/// the bright one over a wash.
public struct TrendsLoadChart: View {
    private let chronic: [Double]
    private let acute: [Double]
    private let tint: DomainTint
    private let startLabel: String
    private let endLabel: String

    public init(chronic: [Double], acute: [Double], tint: DomainTint, startLabel: String, endLabel: String) {
        self.chronic = chronic
        self.acute = acute
        self.tint = tint
        self.startLabel = startLabel
        self.endLabel = endLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                plot(size: proxy.size)
            }
            .frame(height: 76)
            HStack {
                Text(verbatim: startLabel)
                Spacer()
                Text(verbatim: endLabel)
            }
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: NoopMetrics.space3) {
                legendKey(title: "Acute · 7-day", opacity: 1)
                legendKey(title: "Chronic · 42-day", opacity: 0.45)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Acute and chronic training load over the last \(acute.count) days")
    }

    private func legendKey(title: LocalizedStringKey, opacity: Double) -> some View {
        HStack(spacing: 5) {
            Capsule(style: .continuous).fill(tint.accent.opacity(opacity)).frame(width: 12, height: 3)
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    @ViewBuilder
    private func plot(size: CGSize) -> some View {
        let all = (chronic + acute).filter(\.isFinite)
        let low = all.min() ?? 0
        let high = all.max() ?? 1
        let span = max(high - low, 0.0001)
        let pad = span * 0.12
        let lower = low - pad
        let range = span + pad * 2
        let chronicPoints = Self.points(chronic, size: size, lower: lower, range: range)
        let acutePoints = Self.points(acute, size: size, lower: lower, range: range)

        ZStack {
            if acutePoints.count >= 2 {
                Self.area(acutePoints, height: size.height)
                    .fill(LinearGradient(colors: [tint.accent.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
            }
            if chronicPoints.count >= 2 {
                Self.line(chronicPoints)
                    .stroke(tint.accent.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if acutePoints.count >= 2 {
                Self.line(acutePoints)
                    .stroke(tint.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
            if let end = acutePoints.last {
                Circle()
                    .fill(tint.accent)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
            }
        }
    }

    private static func points(_ values: [Double], size: CGSize, lower: Double, range: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                y: size.height * CGFloat(1 - (value - lower) / range)
            )
        }
    }

    private static func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        TrendCurve.append(points, to: &path)
        return path
    }

    private static func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = line(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Weekly review parts

/// Label-over-value columns for the weekly readout: each score's symbol and name, its week mean, and the
/// change against last week in the tone that says whether that is good.
public struct TrendsWeekColumns: View {
    public struct Item: Identifiable {
        public let id: String
        public let systemImage: String
        public let label: String
        public let value: String
        public let delta: String
        public let tone: TrendDeltaTone
        public let tint: DomainTint

        public init(id: String, systemImage: String, label: String, value: String, delta: String,
                    tone: TrendDeltaTone, tint: DomainTint) {
            self.id = id
            self.systemImage = systemImage
            self.label = label
            self.value = value
            self.delta = delta
            self.tone = tone
            self.tint = tint
        }
    }

    private let items: [Item]
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = WidgetMetrics.statValueSize
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(items: [Item]) {
        self.items = items
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                ForEach(items) { item in column(item) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 52)
                            .accessibilityHidden(true)
                    }
                    column(item)
                        .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                        .padding(.trailing, index == items.count - 1 ? 0 : NoopMetrics.space3)
                }
            }
        }
    }

    private func deltaColor(_ tone: TrendDeltaTone) -> Color {
        switch tone {
        case .positive: StrandPalette.statusPositive
        case .negative: StrandPalette.statusCritical
        case .neutral: StrandPalette.textTertiary
        }
    }

    private func column(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: item.systemImage)
                    .font(StrandFont.micro)
                    .foregroundStyle(item.tint.accent)
                    .accessibilityHidden(true)
                Text(verbatim: item.label)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Text(verbatim: item.value)
                .font(StrandFont.number(valueSize, weight: .semibold))
                .foregroundStyle(item.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: item.delta)
                .font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(deltaColor(item.tone))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(item.value), \(item.delta)")
    }
}

/// One of the week's biggest movers: symbol, name, this week's value and the change as a state pill.
public struct TrendsMoverRow: View {
    private let systemImage: String
    private let label: String
    private let isEarlyRead: Bool
    private let value: String
    private let delta: String
    private let tone: StrandTone
    private let tint: DomainTint

    public init(systemImage: String, label: String, isEarlyRead: Bool, value: String, delta: String,
                tone: StrandTone, tint: DomainTint) {
        self.systemImage = systemImage
        self.label = label
        self.isEarlyRead = isEarlyRead
        self.value = value
        self.delta = delta
        self.tone = tone
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Image(systemName: systemImage)
                .font(StrandFont.caption)
                .foregroundStyle(tint.accent)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            Text(verbatim: label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            if isEarlyRead {
                Text("early read")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NoopMetrics.space1)
            Text(verbatim: value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 78, alignment: .trailing)
            StatePill(LocalizedStringKey(delta), tone: tone, showsDot: false)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: spokenSummary))
    }

    /// One spoken line; a rough comparison says so in the listener's language.
    private var spokenSummary: String {
        let base = "\(label), \(value), \(delta)"
        return isEarlyRead ? "\(base), \(String(localized: "early read"))" : base
    }
}
