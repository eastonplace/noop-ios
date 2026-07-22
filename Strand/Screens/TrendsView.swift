import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends
//
// The weekly longitudinal view, rendered only through the canonical Paper score tiles,
// over-time chart, Week in Review card, and distinct insight.

enum TrendSummaryGoodDirection: Equatable {
    case higher, lower, neutral
}

enum TrendSummaryDeltaTone: Equatable {
    case positive, negative, neutral
}

/// Pure presentation derived from the exact `TrendPoint` array handed to the chart.
/// Keeping the source array on the value makes the single-source contract explicit and
/// testable: latest, delta, and the <= 7-point spark never query or rebuild data.
struct TrendSummaryPresentation {
    let source: [TrendPoint]
    let latest: Double?
    let delta: Double?
    let spark: [TrendPoint]
    let deltaTone: TrendSummaryDeltaTone
    let currentCount: Int
    let previousCount: Int
    let expectedCount: Int
    let comparisonIsReliable: Bool

    init(
        series: [TrendPoint],
        previousSeries: [TrendPoint],
        goodDirection: TrendSummaryGoodDirection,
        expectedCount: Int
    ) {
        source = series
        latest = series.last?.value
        let currentMean = Self.mean(series)
        let previousMean = Self.mean(previousSeries)
        delta = currentMean.flatMap { current in previousMean.map { current - $0 } }
        spark = Self.sample(series, maximumCount: 30)
        currentCount = series.count
        previousCount = previousSeries.count
        self.expectedCount = max(1, expectedCount)
        let minimum = max(3, Int(ceil(Double(self.expectedCount) * 0.2)))
        comparisonIsReliable = series.count >= minimum && previousSeries.count >= minimum

        guard comparisonIsReliable, let delta, abs(delta) > 0.000_000_1 else {
            deltaTone = .neutral
            return
        }
        switch goodDirection {
        case .higher:
            deltaTone = delta > 0 ? .positive : .negative
        case .lower:
            deltaTone = delta < 0 ? .positive : .negative
        case .neutral:
            deltaTone = .neutral
        }
    }

    private static func mean(_ series: [TrendPoint]) -> Double? {
        guard !series.isEmpty else { return nil }
        return series.reduce(0) { $0 + $1.value } / Double(series.count)
    }

    /// Keep long-range sparks legible without changing the source or period calculation.
    private static func sample(_ series: [TrendPoint], maximumCount: Int) -> [TrendPoint] {
        guard maximumCount > 1, series.count > maximumCount else { return series }
        return (0..<maximumCount).map { slot in
            let position = Double(slot) * Double(series.count - 1) / Double(maximumCount - 1)
            return series[Int(position.rounded())]
        }
    }
}

struct PaperTrendSeries {
    let recovery: [TrendPoint]
    let strain: [TrendPoint]
    let sleep: [TrendPoint]
    let hrv: [TrendPoint]

    static func build(days: [DailyMetric], sleepByDay: [String: Double],
                      date: (String) -> Date?) -> PaperTrendSeries {
        PaperTrendSeries(
            recovery: days.compactMap { day in
                guard let value = day.recovery, let date = date(day.day) else { return nil }
                return TrendPoint(date: date, value: value)
            },
            strain: days.compactMap { day in
                guard let stored = day.strain, let date = date(day.day) else { return nil }
                return TrendPoint(date: date, value: StrainScale.displayValue(fromStored: stored))
            },
            sleep: days.compactMap { day in
                guard let value = sleepByDay[day.day], let date = date(day.day) else { return nil }
                return TrendPoint(date: date, value: value)
            },
            hrv: days.compactMap { day in
                guard let value = day.avgHrv, let date = date(day.day) else { return nil }
                return TrendPoint(date: date, value: value)
            }
        )
    }
}

private enum ProductionTrendMetric: String, CaseIterable, Identifiable {
    case recovery = "Recovery"
    case strain = "Strain"
    case sleepPerformance = "Sleep performance"
    case sleepDuration = "Sleep duration"
    case hrv = "HRV"
    case restingHR = "Resting HR"
    case respiratory = "Respiratory rate"
    case spo2 = "SpO₂"
    case skinTemp = "Skin temp"
    case steps = "Steps"
    case calories = "Calories"
    case stress = "Stress"

    var id: String { rawValue }
    var tint: Color {
        switch self {
        case .recovery: StrandPalette.recoveryData
        case .strain: StrandPalette.strainAccent
        case .sleepPerformance, .sleepDuration: StrandPalette.sleepAccent
        case .hrv: StrandPalette.metricPurple
        case .restingHR: StrandPalette.metricRose
        case .respiratory: StrandPalette.accent
        case .spo2, .steps: StrandPalette.metricCyan
        case .skinTemp, .calories: StrandPalette.metricAmber
        case .stress: StrandPalette.stressAccent
        }
    }
    var unit: String {
        switch self {
        case .recovery, .sleepPerformance, .spo2: "%"
        case .sleepDuration: "h"
        case .hrv: "ms"
        case .restingHR: "bpm"
        case .respiratory: "rpm"
        case .skinTemp: "°C"
        case .calories: "kcal"
        case .strain, .steps, .stress: ""
        }
    }
    var chartDirection: TrendPanelChart.Direction {
        switch self {
        case .recovery, .sleepPerformance, .hrv, .spo2: .higherIsBetter
        case .restingHR, .stress: .lowerIsBetter
        case .strain, .sleepDuration, .respiratory, .skinTemp, .steps, .calories: .contextual
        }
    }
    func format(_ value: Double) -> String {
        switch self {
        case .strain, .sleepDuration, .respiratory, .skinTemp, .stress:
            return String(format: "%.1f", value)
        case .steps, .calories:
            return Int(value.rounded()).formatted()
        default:
            return "\(Int(value.rounded()))"
        }
    }

    func formatWithUnit(_ value: Double) -> String {
        let rendered = format(value)
        guard !unit.isEmpty else { return rendered }
        return unit == "%" ? "\(rendered)%" : "\(rendered) \(unit)"
    }
}

struct TrendsView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    // #436 — shareable offline trends report (PDF over a date range). The sheet owns its
    // own range picker; this just presents it with the loaded history.
    @State private var showingReport = false

    /// Sleep's per-day series, keyed by "yyyy-MM-dd". Sleep is the sleep_performance COMPOSITE (the same
    /// number the Today Sleep score + the Sleep Sleep-detail plot, #614 follow-up) — NOT raw efficiency,
    /// which read differently under the same "Sleep" label and made the Trends Sleep graph disagree with
    /// the Today Sleep score (#732). sleep_performance is a metricSeries, not a DailyMetric field, so load
    /// it once (mirroring TodayView's restScore source) and key by day for `resolve` below.
    @State private var sleepPerfByDay: [String: Double] = [:]
    @State private var appleDays: [AppleDaily] = []
    @State private var stressByDay: [String: Double] = [:]
    @State private var selectedMetric: ProductionTrendMetric = .recovery
    @State private var selectedRange: TrendRange = .month
    // Original #710 wiring restored by E6: the Paper review card browses the same engine-backed
    // Mon-Sun digests as the pre-reskin screen; 0 is the current week and negatives step backward.
    @State private var weekOffset: Int

    init(initialWeekOffset: Int = 0) {
        _weekOffset = State(initialValue: min(0, initialWeekOffset))
    }

    private var trendReferenceDate: Date { Calendar.current.startOfDay(for: Date()) }

    private func date(_ day: String) -> Date? { localDate(day) }

    /// All calendar-shaped presentation uses one local civil-date conversion. A repository key is a
    /// civil day, not an instant; parsing it at UTC midnight shifts the apparent weekday in western zones.
    private func localDate(_ day: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }

    var body: some View {
        // The liquid metric cards now tap through to their MetricDetailView (matching Today's card
        // taps + Explore's rows). On iOS each tab already supplies a NavigationStack, so those pushes
        // land in the ambient stack. On macOS the .trends detail pane has NO enclosing NavigationStack
        // (RootView), so — exactly like MetricExplorerView (#753) — wrap the scaffold in one here so the
        // pushes get Back chrome instead of hanging. The SAME shared scaffold renders on both.
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(title: "Trends", subtitle: "Selected ranges and weekly reviews.",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       onRefresh: { _ = await repo.refresh(.currentDay) },
                       lazy: true,
                       topBackground: nil,
                       trailing: {
                           HStack(spacing: 12) {
                               Image(systemName: "calendar")
                               Button { showingReport = true } label: { Image(systemName: "square.and.arrow.up") }
                                   .buttonStyle(.plain)
                           }
                           .font(.system(size: 15, weight: .medium))
                           .foregroundStyle(StrandPalette.textPrimary)
                       }) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    paperScoresOverTime
                    paperWeekReview
                }
            }
        }
        // #436 — present the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.canonicalDays)
        }
        // #732 — load the resolved sleep_performance series so Sleep plots the SAME composite the Today
        // Sleep score uses (not raw efficiency). Mirrors TodayView's restScore read. Keyed on the day
        // count so a newly-banked/-scored night refreshes Sleep reactively, like the other metrics that
        // read `repo.days` directly (and like the Android LaunchedEffect(days) twin).
        .task(id: repo.days.count) {
            async let sleepSeries = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            async let stressSeries = repo.exploreSeries(key: "stress", source: "my-whoop")
            async let appleRows = repo.appleDailyRows()
            let s = await sleepSeries
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            let stress = await stressSeries
            stressByDay = Dictionary(stress.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            appleDays = await appleRows
        }
    }

    // MARK: - Paper Trends (S2)

    private var paperDigest: WeeklyDigest {
        WeeklyDigestSource.digest(from: repo.canonicalDays, anchorDay: weekAnchorDay,
                                  sleepByDay: sleepPerfByDay)
    }

    private var paperWeekDays: [DailyMetric] {
        let digest = paperDigest
        return repo.canonicalDays.filter { $0.day >= digest.weekStart && $0.day <= digest.weekEnd }
    }

    private var paperWeekDates: [Date] { paperWeekDays.compactMap { date($0.day) } }

    private var paperWeekRangeLabel: String {
        let digest = paperDigest
        guard let start = date(digest.weekStart), let end = date(digest.weekEnd) else { return "" }
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("MMM d")
        return "\(f.string(from: start)) — \(f.string(from: end))"
    }

    private var paperScoreTiles: some View {
        HStack(alignment: .top, spacing: 8) {
            paperScoreTile(
                .charge,
                accent: paperDigest.summary(.charge).flatMap { summary in
                    summary.thisWeek.n > 0 ? RecoveryBands.color(for: summary.thisWeek.mean) : nil
                } ?? StrandPalette.recoveryData
            )
            paperScoreTile(.effort, accent: StrandPalette.strainAccent)
            paperScoreTile(.rest, accent: StrandPalette.sleepAccent)
        }
    }

    /// The compact rows follow the selected W/M/3M/6M range, not the review card's
    /// Monday-Sunday week. The immediately preceding equal-length range supplies the delta.
    private var paperTrendSeries: PaperTrendSeries {
        PaperTrendSeries.build(days: paperRangeDays(periodOffset: 0), sleepByDay: sleepPerfByDay, date: date)
    }

    private var previousPaperTrendSeries: PaperTrendSeries {
        PaperTrendSeries.build(days: paperRangeDays(periodOffset: -1), sleepByDay: sleepPerfByDay, date: date)
    }

    private func paperRangeDays(periodOffset: Int) -> [DailyMetric] {
        let calendar = Calendar.current
        guard let period = TrendCalendar.equalLengthPeriod(
            through: trendReferenceDate,
            count: selectedRange.days,
            periodOffset: periodOffset,
            calendar: calendar
        ) else { return [] }
        return repo.canonicalDays.filter { day in
            guard let stamp = localDate(day.day, calendar: calendar) else { return false }
            return period.contains(stamp)
        }
    }

    private func paperScoreTile(_ metric: WeeklyMetric, accent: Color) -> some View {
        let summary = paperDigest.summary(metric)
        let hasValue = (summary?.thisWeek.n ?? 0) > 0
        let mean = summary?.thisWeek.mean ?? 0
        let value: String = hasValue
            ? (metric == .effort ? StrainScale.formatted(mean) : "\(Int(mean.rounded()))")
            : "—"
        let delta = summary?.wowDelta ?? 0
        let sign = delta >= 0 ? "+" : "−"
        return PaperCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(metric.label))
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(accent)
                Text(value).font(StrandFont.statValue).foregroundStyle(StrandPalette.textPrimary)
                Text(hasValue
                     ? "\(sign)\(metric == .effort ? StrainScale.formattedDelta(abs(delta)) : "\(Int(abs(delta).rounded()))") vs last week"
                     : "No data this week")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        }
    }

    private var paperScoresOverTime: some View {
        let series = paperTrendSeries
        let previousSeries = previousPaperTrendSeries
        let referenceDate = trendReferenceDate
        let selectedPoints = selectedTrendPoints
        let selectedDateDomain = TrendCalendar.dateDomain(
            through: referenceDate, count: selectedRange.days, calendar: .current
        ) ?? referenceDate...referenceDate
        let calendarDays = TrendCalendar.buildFiveWeekWindow(
            observations: selectedTrendCalendarObservations,
            through: referenceDate
        )
        let weekdayAverages = TrendCalendar.weekdayAverages(selectedTrendCalendarDays)
        let baseline = selectedTrendBaseline
        let spread = max(selectedTrendSpread, 0.5)
        let typical = (baseline - spread)...(baseline + spread)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected range").strandOverline()
                Text("Last \(selectedRange.days) calendar days through today")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            HStack(spacing: 7) {
                metricDropdown
                Spacer(minLength: 8)
                ForEach(TrendRange.allCases) { range in
                    rangeChip(range)
                }
            }
            if !selectedPoints.isEmpty {
                TrendPanelChart(
                    days: selectedTrendCalendarDays,
                    dateDomain: selectedDateDomain,
                    referenceDate: referenceDate,
                    calendar: .current,
                    baseline: baseline,
                    typical: typical,
                    tint: selectedMetric.tint,
                    unit: selectedMetric.unit,
                    valueFormat: selectedMetric.format,
                    range: selectedRange,
                    direction: selectedMetric.chartDirection
                )
                .id("\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
                if selectedRange != .week {
                    Text("Calendar heat · latest 35 days")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textSecondary)
                    TrendMonthHeat(days: calendarDays, tint: selectedMetric.tint,
                                   referenceDate: referenceDate,
                                   valueFormat: selectedMetric.format,
                                   colorScale: selectedMetric == .recovery ? .recoveryBands : .intensity)
                        .id("heat-\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
                }
            }
            trendV2Row("Recovery", points: series.recovery, previousPoints: previousSeries.recovery,
                       goodDirection: .higher, tint: StrandPalette.recoveryData,
                       format: { "\(Int($0.rounded()))" })
            trendV2Row("Strain", points: series.strain, previousPoints: previousSeries.strain,
                       goodDirection: .neutral, tint: StrandPalette.strainAccent,
                       format: StrainScale.formatted)
            trendV2Row("Sleep", points: series.sleep, previousPoints: previousSeries.sleep,
                       goodDirection: .higher, tint: StrandPalette.sleepAccent,
                       format: { "\(Int($0.rounded()))%" })
            trendV2Row("HRV", points: series.hrv, previousPoints: previousSeries.hrv,
                       goodDirection: .higher, tint: StrandPalette.metricPurple,
                       format: { "\(Int($0.rounded())) ms" })
            if !weekdayAverages.compactMap({ $0 }).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedRange.averageHeading).strandOverline()
                    Text("By weekday · \(selectedRange.days) calendar days")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                TrendWeekdayBars(
                    values: weekdayAverages,
                    tint: selectedMetric.tint,
                    referenceDate: referenceDate,
                    calendar: .current,
                    valueFormat: selectedMetric.formatWithUnit
                )
                    .frame(height: 150)
            }
        }
    }

    private var selectedTrendPoints: [TrendPoint] {
        selectedTrendCalendarDays.compactMap { day in
            day.value.map { TrendPoint(date: day.date, value: $0) }
        }
    }

    private var selectedTrendCalendarDays: [CalendarMetricDay] {
        TrendCalendar.buildRollingWindow(
            observations: selectedTrendCalendarObservations,
            through: trendReferenceDate,
            count: selectedRange.days,
            calendar: .current
        )
    }

    private var selectedTrendCalendarObservations: [CalendarMetricDay] {
        let apple = Dictionary(appleDays.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return repo.canonicalDays.compactMap { day in
            guard let stamp = localDate(day.day) else { return nil }
            return CalendarMetricDay(date: stamp, value: selectedMetricValue(for: day, apple: apple))
        }
    }

    private func selectedMetricValue(for day: DailyMetric, apple: [String: AppleDaily]) -> Double? {
        switch selectedMetric {
        case .recovery: day.recovery
        case .strain: day.strain.map(StrainScale.displayValue(fromStored:))
        case .sleepPerformance: sleepPerfByDay[day.day]
        case .sleepDuration: day.totalSleepMin.map { $0 / 60 }
        case .hrv: day.avgHrv
        case .restingHR: day.restingHr.map(Double.init)
        case .respiratory: day.respRateBpm
        case .spo2: day.spo2Pct
        case .skinTemp: day.skinTempDevC
        case .steps: day.steps.map(Double.init) ?? apple[day.day]?.steps.map(Double.init)
        case .calories: day.activeKcalEst ?? apple[day.day]?.activeKcal
        case .stress: stressByDay[day.day]
        }
    }

    private var selectedTrendBaseline: Double {
        let values = selectedTrendPoints.map(\.value)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private var selectedTrendSpread: Double {
        let values = selectedTrendPoints.map(\.value)
        guard values.count > 1 else { return max(abs(selectedTrendBaseline) * 0.1, 1) }
        let mean = selectedTrendBaseline
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return max(sqrt(variance), abs(mean) * 0.04)
    }

    private var metricDropdown: some View {
        Menu {
            ForEach(ProductionTrendMetric.allCases) { metric in
                Button {
                    selectedMetric = metric
                } label: {
                    if selectedMetric == metric {
                        Label(metric.rawValue, systemImage: "checkmark")
                    } else {
                        Text(metric.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(selectedMetric.tint).frame(width: 7, height: 7)
                Text(selectedMetric.rawValue).font(StrandFont.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(StrandPalette.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(StrandPalette.hairlineStrong, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metric: \(selectedMetric.rawValue). Opens the metric list")
    }

    private func rangeChip(_ range: TrendRange) -> some View {
        Button { selectedRange = range } label: {
            Text(range.rawValue)
                .font(StrandFont.micro.weight(.semibold)).fixedSize()
                .foregroundStyle(selectedRange == range ? StrandPalette.appCanvas : StrandPalette.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 8)
                .background(selectedRange == range ? StrandPalette.textPrimary : StrandPalette.surfaceRaised,
                            in: Capsule())
                .overlay(Capsule().stroke(StrandPalette.hairlineStrong,
                                          lineWidth: selectedRange == range ? 0 : 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(range.days) days")
    }

    private func trendV2Row(
        _ label: String,
        points: [TrendPoint],
        previousPoints: [TrendPoint],
        goodDirection: TrendSummaryGoodDirection,
        tint: Color,
        format: (Double) -> String
    ) -> some View {
        let presentation = TrendSummaryPresentation(
            series: points,
            previousSeries: previousPoints,
            goodDirection: goodDirection,
            expectedCount: selectedRange.days
        )
        let tone: TrendDeltaTone
        switch presentation.deltaTone {
        case .positive: tone = .positive
        case .negative: tone = .negative
        case .neutral: tone = .neutral
        }
        let deltaText = !presentation.comparisonIsReliable
            ? "Early read · \(presentation.currentCount)/\(presentation.expectedCount) days"
            : presentation.delta.map { delta in
            "\(delta >= 0 ? "+" : "−")\(format(abs(delta))) avg"
        } ?? "Need prior data"
        return TrendDeltaRow(
            label: label,
            subtitle: selectedRange.summarySubtitle,
            values: presentation.spark.map(\.value),
            latest: presentation.latest.map(format) ?? "—",
            delta: deltaText,
            tone: tone,
            tint: tint
        )
    }

    private func paperLegend(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var paperReviewLines: [String] {
        // Craft pass (003): the balance sentence renders in the Insight card, so it must NOT
        // also appear as a review bullet — same copy twice on one screen reads broken.
        let digest = paperDigest
        let lines = Array(digest.focalPoints.prefix(3))
        return lines.isEmpty ? [digest.balance.sentence] : lines
    }

    /// F6: the card never disappears. Prefer the engine's balance read, then the next
    /// focal point not already used by Week in Review. When the engine has emitted no
    /// second distinct read yet, keep the slot honest instead of repeating a bullet.
    private var paperInsightText: String {
        let candidates = [paperDigest.balance.sentence] + paperDigest.focalPoints
        return candidates.first(where: { !paperReviewLines.contains($0) })
            ?? String(localized: "Keep logging this week. The next distinct pattern will appear as soon as it clears the weekly signal threshold.")
    }

    /// Bullet dot tinted by the pillar the sentence is about (board v2's colored review dots);
    /// neutral when no pillar is named.
    private func reviewDotColor(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("recovery") || l.contains("hrv") { return StrandPalette.recoveryData }
        if l.contains("strain") { return StrandPalette.strainAccent }
        if l.contains("sleep") { return StrandPalette.sleepAccent }
        if l.contains("stress") { return StrandPalette.stressAccent }
        return StrandPalette.textTertiary
    }

    private var paperMoverRows: [WeeklyMetricSummary] {
        Array(
            paperDigest.metrics
                .filter { $0.weekOverWeek.current.n > 0 && $0.weekOverWeek.previous.n > 0 }
                .sorted { abs($0.normalisedMove) > abs($1.normalisedMove) }
                .prefix(3)
        )
    }

    private func paperMoverAccent(_ metric: WeeklyMetric) -> Color {
        switch metric {
        case .charge: StrandPalette.recoveryData
        case .effort: StrandPalette.strainAccent
        case .rest: StrandPalette.sleepAccent
        case .rhr: StrandPalette.metricRose
        case .hrv: StrandPalette.metricPurple
        }
    }

    private func paperMoverValue(_ summary: WeeklyMetricSummary) -> String {
        let value = summary.thisWeek.mean
        switch summary.metric {
        case .effort: return StrainScale.formatted(value)
        case .rhr: return "\(Int(value.rounded())) bpm"
        case .hrv: return "\(Int(value.rounded())) ms"
        case .charge, .rest: return "\(Int(value.rounded()))"
        }
    }

    private func paperMoverDelta(_ summary: WeeklyMetricSummary) -> String {
        let delta = summary.wowDelta
        let magnitude: String
        switch summary.metric {
        case .effort: magnitude = StrainScale.formattedDelta(abs(delta))
        case .rhr: magnitude = "\(Int(abs(delta).rounded())) bpm"
        case .hrv: magnitude = "\(Int(abs(delta).rounded())) ms"
        case .charge, .rest: magnitude = "\(Int(abs(delta).rounded()))"
        }
        return "\(delta >= 0 ? "+" : "−")\(magnitude)"
    }

    private func paperMoverTone(_ summary: WeeklyMetricSummary) -> Color {
        guard !summary.isRoughComparison else { return StrandPalette.textTertiary }
        switch summary.wowGoodness {
        case 1: return StrandPalette.statusPositive
        case -1: return StrandPalette.statusCritical
        default: return StrandPalette.textSecondary
        }
    }

    private var paperWeekReview: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { stepWeek(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset <= minWeekOffset ? StrandPalette.textTertiary : StrandPalette.link)
                    .disabled(weekOffset <= minWeekOffset)
                    .accessibilityLabel("Previous week")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly readout").strandOverline()
                        Text(weekOffsetLabel).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Text("\(paperDigest.daysWithData)/7 days")
                        .font(StrandFont.micro.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(StrandPalette.surfaceInset, in: Capsule())
                    Button { stepWeek(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset >= 0 ? StrandPalette.textTertiary : StrandPalette.link)
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Next week")
                }

                paperScoreTiles

                if !paperMoverRows.isEmpty {
                    Text("Biggest changes").strandOverline()
                    VStack(spacing: 9) {
                        ForEach(paperMoverRows, id: \.metric.rawValue) { summary in
                            HStack(spacing: 9) {
                                Circle().fill(paperMoverAccent(summary.metric)).frame(width: 7, height: 7)
                                Text(summary.metric.label)
                                    .font(StrandFont.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                if summary.isRoughComparison {
                                    Text("early read")
                                        .font(StrandFont.micro)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer(minLength: 8)
                                Text(paperMoverValue(summary))
                                    .font(StrandFont.captionNumber.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(paperMoverDelta(summary))
                                    .font(StrandFont.micro.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(paperMoverTone(summary))
                                    .frame(minWidth: 50, alignment: .trailing)
                            }
                        }
                    }
                }

                if let consistency = paperDigest.sleepConsistencySD {
                    Label("Sleep consistency ±\(Int(consistency.rounded())) points", systemImage: "moon.zzz")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                Divider().overlay(StrandPalette.hairline)

                ForEach(Array(paperReviewLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(reviewDotColor(for: line)).frame(width: 7, height: 7).padding(.top, 6)
                        Text(line)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.link)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Insight").strandOverline()
                        Text(paperInsightText)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var minWeekOffset: Int {
        guard let earliest = repo.days.first?.day,
              let earliestMonday = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
              let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: Repository.localDayKey(Date()))
        else { return 0 }
        var offset = 0
        var monday = thisMonday
        while monday > earliestMonday && offset > -520 {
            monday = WeeklyDigestEngine.addDays(monday, -7)
            offset -= 1
        }
        return offset
    }

    private var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(trendReferenceDate), weekOffset * 7)
    }

    private func stepWeek(_ delta: Int) {
        weekOffset = max(minWeekOffset, min(0, weekOffset + delta))
    }

    private var weekOffsetLabel: String {
        let weeksAgo = -weekOffset
        if weeksAgo == 0 { return String(localized: "This week") }
        if weeksAgo == 1 { return String(localized: "Last week") }
        return String(localized: "\(weeksAgo) weeks ago")
    }

    @ViewBuilder private var paperInsight: some View {
        InsightCard(symbol: "sparkles", title: "Insight",
                    body: LocalizedStringKey(paperInsightText), accent: StrandPalette.link)
    }

}

private struct TrendSummaryRow: View {
    let title: LocalizedStringKey
    let presentation: TrendSummaryPresentation
    let color: Color
    let gradient: Gradient
    let valueFormat: (Double) -> String
    let deltaFormat: (Double) -> String

    private var valueText: String {
        presentation.latest.map(valueFormat) ?? "—"
    }

    private var deltaText: String {
        guard let delta = presentation.delta else { return "—" }
        if abs(delta) <= 0.000_000_1 { return "0" }
        return "\(delta > 0 ? "+" : "−")\(deltaFormat(delta))"
    }

    private var deltaColor: Color {
        switch presentation.deltaTone {
        case .positive: return StrandPalette.statusPositive
        case .negative: return StrandPalette.statusCritical
        case .neutral: return StrandPalette.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            if presentation.spark.count > 1 {
                Sparkline(
                    values: presentation.spark.map(\.value),
                    gradient: gradient,
                    lineWidth: 1.6,
                    showsArea: false,
                    showsHead: false,
                    showsHover: false
                )
                .frame(width: 64, height: 18)
                .opacity(0.85)
                .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 64, height: 18)
            }
            Text(valueText)
                .font(StrandFont.captionNumber.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 34, alignment: .trailing)
            Text(deltaText)
                .font(StrandFont.micro.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(deltaColor)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
