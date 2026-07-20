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

    init(series: [TrendPoint], goodDirection: TrendSummaryGoodDirection) {
        source = series
        latest = series.last?.value
        delta = series.count > 1 ? series[series.count - 1].value - series[series.count - 2].value : nil
        spark = Array(series.suffix(7))

        guard let delta, abs(delta) > 0.000_000_1 else {
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

    // yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    /// Calendar heatmaps use local civil dates. The UTC parser above remains correct for line-chart
    /// timestamps, but normalizing UTC midnight in a western timezone would shift every cell back a day.
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
        ScreenScaffold(title: LocalizedStringKey(weekOffsetLabel), subtitle: LocalizedStringKey(paperWeekRangeLabel),
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       onRefresh: { await repo.refresh() },
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
                    paperScoreTiles
                    paperScoresOverTime
                    paperWeekReview
                    paperInsight
                }
            }
        }
        // #436 — present the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.days)
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
        WeeklyDigestSource.digest(from: repo.days, anchorDay: weekAnchorDay)
    }

    private var paperWeekDays: [DailyMetric] {
        let digest = paperDigest
        return repo.days.filter { $0.day >= digest.weekStart && $0.day <= digest.weekEnd }
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

    /// One derivation for both the chart marks and summary rows. Do not split this
    /// back into view-local maps: T030 pins the exact shared arrays.
    private var paperTrendSeries: PaperTrendSeries {
        PaperTrendSeries.build(days: paperWeekDays, sleepByDay: sleepPerfByDay, date: date)
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
        let selectedValues = selectedTrendPoints.map(\.value)
        let referenceDate = Date()
        let calendarDays = TrendCalendar.buildFiveWeekWindow(
            observations: selectedTrendCalendarObservations,
            through: referenceDate
        )
        let weekdayAverages = TrendCalendar.weekdayAverages(calendarDays)
        let baseline = selectedTrendBaseline
        let spread = max(selectedTrendSpread, 0.5)
        let typical = (baseline - spread)...(baseline + spread)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                metricDropdown
                Spacer(minLength: 8)
                ForEach(TrendRange.allCases) { range in
                    rangeChip(range)
                }
            }
            if !selectedValues.isEmpty {
                TrendPanelChart(
                    values: selectedValues,
                    baseline: baseline,
                    typical: typical,
                    tint: selectedMetric.tint,
                    unit: selectedMetric.unit,
                    valueFormat: selectedMetric.format,
                    range: selectedRange
                )
                .id("\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
                if selectedRange != .week {
                    TrendMonthHeat(days: calendarDays, tint: selectedMetric.tint,
                                   referenceDate: referenceDate,
                                   valueFormat: selectedMetric.format,
                                   colorScale: selectedMetric == .recovery ? .recoveryBands : .intensity)
                        .id("heat-\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
                }
            }
            trendV2Row("Recovery", points: series.recovery, tint: StrandPalette.recoveryData,
                       format: { "\(Int($0.rounded()))" })
            trendV2Row("Strain", points: series.strain, tint: StrandPalette.strainAccent,
                       format: StrainScale.formatted)
            trendV2Row("Sleep", points: series.sleep, tint: StrandPalette.sleepAccent,
                       format: { "\(Int($0.rounded()))%" })
            trendV2Row("HRV", points: series.hrv, tint: StrandPalette.metricPurple,
                       format: { "\(Int($0.rounded())) ms" })
            if !weekdayAverages.compactMap({ $0 }).isEmpty {
                TrendWeekdayBars(values: weekdayAverages, tint: selectedMetric.tint)
                    .frame(height: 150)
            }
        }
    }

    private var selectedTrendPoints: [TrendPoint] {
        let apple = Dictionary(appleDays.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return repo.days.suffix(selectedRange.days).compactMap { day in
            guard let stamp = date(day.day) else { return nil }
            let value = selectedMetricValue(for: day, apple: apple)
            return value.map { TrendPoint(date: stamp, value: $0) }
        }
    }

    private var selectedTrendCalendarObservations: [TrendCalendarDay] {
        let apple = Dictionary(appleDays.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return repo.days.compactMap { day in
            guard let stamp = localDate(day.day) else { return nil }
            return TrendCalendarDay(date: stamp, value: selectedMetricValue(for: day, apple: apple))
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
        tint: Color,
        format: (Double) -> String
    ) -> some View {
        let values = points.map(\.value)
        let latest = values.last
        let prior = values.dropLast().last
        let delta = latest.flatMap { current in prior.map { current - $0 } }
        return TrendDeltaRow(
            label: label,
            subtitle: "This week",
            values: values,
            latest: latest.map(format) ?? "—",
            delta: delta.map { "\($0 >= 0 ? "+" : "−")\(format(abs($0)))" } ?? "—",
            positive: (delta ?? 0) >= 0,
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

    private var paperWeekReview: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { stepWeek(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset <= minWeekOffset ? StrandPalette.textTertiary : StrandPalette.link)
                    .disabled(weekOffset <= minWeekOffset)
                    .accessibilityLabel("Previous week")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Week in Review").strandOverline()
                        Text(weekOffsetLabel).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Button { stepWeek(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset >= 0 ? StrandPalette.textTertiary : StrandPalette.link)
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Next week")
                }
                ForEach(Array(paperReviewLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 9) {
                        ZStack {
                            Circle().fill(reviewDotColor(for: line))
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white)
                        }
                        .frame(width: 18, height: 18)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                        Text(line).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
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
