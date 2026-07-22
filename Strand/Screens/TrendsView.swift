import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends

enum TrendSummaryGoodDirection: Equatable {
    case higher, lower, neutral
}

enum TrendSummaryDeltaTone: Equatable {
    case positive, negative, neutral
}

/// Pure presentation derived from the exact `TrendPoint` array handed to the chart.
/// Latest, period delta, reliability, and compact spark all share one source.
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
        spark = TrendPointExtremaSampler.sample(series, maximumCount: 30)
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
    @EnvironmentObject private var repo: Repository

    @State private var showingReport = false
    @State private var loadedData = TrendsLoadedData.empty
    @State private var selectedMetric: ProductionTrendMetric = .recovery
    @State private var selectedRange: TrendRange = .month
    /// Zero is the current Monday-Sunday digest; negative values step backward.
    @State private var weekOffset: Int

    init(initialWeekOffset: Int = 0) {
        _weekOffset = State(initialValue: min(0, initialWeekOffset))
    }

    /// During the first frame, use Repository's already-published canonical projection. After the auxiliary
    /// reads finish, every Trends section consumes the same captured revision from `loadedData`.
    private var canonicalDays: [DailyMetric] {
        loadedData.canonicalDays.isEmpty ? repo.canonicalDays : loadedData.canonicalDays
    }

    private var sleepPerfByDay: [String: Double] { loadedData.sleepPerfByDay }
    private var stressByDay: [String: Double] { loadedData.stressByDay }
    private var appleByDay: [String: AppleDaily] { loadedData.appleByDay }
    private var trendReferenceDate: Date { Calendar.current.startOfDay(for: Date()) }

    private func date(_ day: String) -> Date? { localDate(day) }

    /// Repository day keys are local civil days, not UTC instants.
    private func localDate(_ day: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }

    var body: some View {
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(
            title: "Trends",
            subtitle: "Selected ranges and weekly reviews.",
            onRefresh: { _ = await repo.refresh(.currentDay) },
            lazy: true,
            topBackground: nil,
            trailing: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                    Button { showingReport = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
            }
        ) {
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
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: canonicalDays)
        }
        // A rescore can replace values without changing the number of day rows. `refreshSeq`, not count,
        // is the revision contract. `.task(id:)` cancels a superseded load; one assignment below prevents
        // Sleep, Stress, and Apple fallback data from briefly describing different revisions.
        .task(id: repo.refreshSeq) {
            await loadDataForCurrentRevision()
        }
    }

    @MainActor
    private func loadDataForCurrentRevision() async {
        let revisionDays = repo.canonicalDays
        async let sleepSeries = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressSeries = repo.exploreSeries(key: "stress", source: "my-whoop")
        async let appleRows = repo.appleDailyRows()

        let (sleep, stress, apple) = await (sleepSeries, stressSeries, appleRows)
        guard !Task.isCancelled else { return }

        loadedData = TrendsLoadedData(
            canonicalDays: revisionDays,
            sleepPerfByDay: Dictionary(
                sleep.map { ($0.day, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            stressByDay: Dictionary(
                stress.map { ($0.day, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            appleDays: apple
        )
    }

    // MARK: - Selected range

    private func rangeDays(periodOffset: Int) -> [DailyMetric] {
        let calendar = Calendar.current
        guard let period = TrendCalendar.equalLengthPeriod(
            through: trendReferenceDate,
            count: selectedRange.days,
            periodOffset: periodOffset,
            calendar: calendar
        ) else { return [] }
        return canonicalDays.filter { day in
            guard let stamp = localDate(day.day, calendar: calendar) else { return false }
            return period.contains(stamp)
        }
    }

    private var paperScoresOverTime: some View {
        let currentDays = rangeDays(periodOffset: 0)
        let previousDays = rangeDays(periodOffset: -1)
        let series = PaperTrendSeries.build(
            days: currentDays,
            sleepByDay: sleepPerfByDay,
            date: date
        )
        let previousSeries = PaperTrendSeries.build(
            days: previousDays,
            sleepByDay: sleepPerfByDay,
            date: date
        )

        // Build the selected metric's calendar projection exactly once per body evaluation and thread the
        // immutable result through the main chart, heat map, and weekday aggregation.
        let observations = selectedMetricObservations
        let selectedCalendarDays = TrendCalendar.buildRollingWindow(
            observations: observations,
            through: trendReferenceDate,
            count: selectedRange.days,
            calendar: .current
        )
        let selectedPoints = selectedCalendarDays.compactMap { day in
            day.value.map { TrendPoint(date: day.date, value: $0) }
        }
        let selectedDateDomain = TrendCalendar.dateDomain(
            through: trendReferenceDate,
            count: selectedRange.days,
            calendar: .current
        ) ?? trendReferenceDate...trendReferenceDate
        let calendarDays = TrendCalendar.buildFiveWeekWindow(
            observations: observations,
            through: trendReferenceDate
        )
        let weekdayAverages = TrendCalendar.weekdayAverages(selectedCalendarDays)
        let values = selectedPoints.map(\.value)
        let baseline = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let spread: Double = {
            guard values.count > 1 else { return max(abs(baseline) * 0.1, 1) }
            let variance = values.reduce(0) { $0 + pow($1 - baseline, 2) } / Double(values.count)
            return max(sqrt(variance), abs(baseline) * 0.04)
        }()
        let typical = (baseline - max(spread, 0.5))...(baseline + max(spread, 0.5))

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
                    days: selectedCalendarDays,
                    dateDomain: selectedDateDomain,
                    referenceDate: trendReferenceDate,
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
                    TrendMonthHeat(
                        days: calendarDays,
                        tint: selectedMetric.tint,
                        referenceDate: trendReferenceDate,
                        valueFormat: selectedMetric.format,
                        colorScale: selectedMetric == .recovery ? .recoveryBands : .intensity
                    )
                    .id("heat-\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
                }
            }

            trendV2Row(
                "Recovery",
                points: series.recovery,
                previousPoints: previousSeries.recovery,
                goodDirection: .higher,
                tint: StrandPalette.recoveryData,
                format: { "\(Int($0.rounded()))" }
            )
            trendV2Row(
                "Strain",
                points: series.strain,
                previousPoints: previousSeries.strain,
                goodDirection: .neutral,
                tint: StrandPalette.strainAccent,
                format: StrainScale.formatted
            )
            trendV2Row(
                "Sleep",
                points: series.sleep,
                previousPoints: previousSeries.sleep,
                goodDirection: .higher,
                tint: StrandPalette.sleepAccent,
                format: { "\(Int($0.rounded()))%" }
            )
            trendV2Row(
                "HRV",
                points: series.hrv,
                previousPoints: previousSeries.hrv,
                goodDirection: .higher,
                tint: StrandPalette.metricPurple,
                format: { "\(Int($0.rounded())) ms" }
            )

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
                    referenceDate: trendReferenceDate,
                    calendar: .current,
                    valueFormat: selectedMetric.formatWithUnit
                )
                .frame(height: 150)
            }
        }
    }

    private var selectedMetricObservations: [CalendarMetricDay] {
        canonicalDays.compactMap { day in
            guard let stamp = localDate(day.day) else { return nil }
            return CalendarMetricDay(
                date: stamp,
                value: selectedMetricValue(for: day, apple: appleByDay)
            )
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
                Text(selectedMetric.rawValue)
                    .font(StrandFont.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(StrandPalette.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(StrandPalette.hairlineStrong, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metric: \(selectedMetric.rawValue). Opens the metric list")
    }

    private func rangeChip(_ range: TrendRange) -> some View {
        Button { selectedRange = range } label: {
            Text(range.rawValue)
                .font(StrandFont.micro.weight(.semibold))
                .fixedSize()
                .foregroundStyle(selectedRange == range
                    ? StrandPalette.appCanvas
                    : StrandPalette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(
                    selectedRange == range
                        ? StrandPalette.textPrimary
                        : StrandPalette.surfaceRaised,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        StrandPalette.hairlineStrong,
                        lineWidth: selectedRange == range ? 0 : 0.75
                    )
                )
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

    // MARK: - Weekly review

    private var paperWeekReview: some View {
        let digest = WeeklyDigestSource.digest(
            from: canonicalDays,
            anchorDay: weekAnchorDay,
            sleepByDay: sleepPerfByDay
        )
        let reviewLines = paperReviewLines(digest)
        let movers = paperMoverRows(digest)
        let insight = paperInsightText(digest, reviewLines: reviewLines)

        return PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { stepWeek(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset <= minWeekOffset
                        ? StrandPalette.textTertiary
                        : StrandPalette.link)
                    .disabled(weekOffset <= minWeekOffset)
                    .accessibilityLabel("Previous week")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly readout").strandOverline()
                        Text(weekOffsetLabel)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }

                    Spacer()

                    Text("\(digest.daysWithData)/7 days")
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
                    .foregroundStyle(weekOffset >= 0
                        ? StrandPalette.textTertiary
                        : StrandPalette.link)
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Next week")
                }

                paperScoreTiles(digest)

                if !movers.isEmpty {
                    Text("Biggest changes").strandOverline()
                    VStack(spacing: 9) {
                        ForEach(movers, id: \.metric.rawValue) { summary in
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(paperMoverAccent(summary.metric))
                                    .frame(width: 7, height: 7)
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

                if let consistency = digest.sleepConsistencySD {
                    Label(
                        "Sleep consistency ±\(Int(consistency.rounded())) points",
                        systemImage: "moon.zzz"
                    )
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                }

                Divider().overlay(StrandPalette.hairline)

                ForEach(Array(reviewLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(reviewDotColor(for: line))
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
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
                        Text(insight)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(
                    StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }
    }

    private func paperScoreTiles(_ digest: WeeklyDigest) -> some View {
        HStack(alignment: .top, spacing: 8) {
            paperScoreTile(
                .charge,
                digest: digest,
                accent: digest.summary(.charge).flatMap { summary in
                    summary.thisWeek.n > 0
                        ? RecoveryBands.color(for: summary.thisWeek.mean)
                        : nil
                } ?? StrandPalette.recoveryData
            )
            paperScoreTile(.effort, digest: digest, accent: StrandPalette.strainAccent)
            paperScoreTile(.rest, digest: digest, accent: StrandPalette.sleepAccent)
        }
    }

    private func paperScoreTile(
        _ metric: WeeklyMetric,
        digest: WeeklyDigest,
        accent: Color
    ) -> some View {
        let summary = digest.summary(metric)
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
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text(value)
                    .font(StrandFont.statValue)
                    .foregroundStyle(StrandPalette.textPrimary)
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

    private func paperReviewLines(_ digest: WeeklyDigest) -> [String] {
        let lines = Array(digest.focalPoints.prefix(3))
        return lines.isEmpty ? [digest.balance.sentence] : lines
    }

    private func paperInsightText(_ digest: WeeklyDigest, reviewLines: [String]) -> String {
        let candidates = [digest.balance.sentence] + digest.focalPoints
        return candidates.first(where: { !reviewLines.contains($0) })
            ?? String(localized: "Keep logging this week. The next distinct pattern will appear as soon as it clears the weekly signal threshold.")
    }

    private func reviewDotColor(for line: String) -> Color {
        let lowered = line.lowercased()
        if lowered.contains("recovery") || lowered.contains("hrv") {
            return StrandPalette.recoveryData
        }
        if lowered.contains("strain") { return StrandPalette.strainAccent }
        if lowered.contains("sleep") { return StrandPalette.sleepAccent }
        if lowered.contains("stress") { return StrandPalette.stressAccent }
        return StrandPalette.textTertiary
    }

    private func paperMoverRows(_ digest: WeeklyDigest) -> [WeeklyMetricSummary] {
        Array(
            digest.metrics
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

    private var minWeekOffset: Int {
        guard let earliest = canonicalDays.first?.day,
              let earliestMonday = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
              let thisMonday = WeeklyDigestEngine.mondayOfWeek(
                containing: Repository.localDayKey(Date())
              )
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
        WeeklyDigestEngine.addDays(
            Repository.localDayKey(trendReferenceDate),
            weekOffset * 7
        )
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
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let calendar = Calendar(identifier: .gregorian)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3

    for index in stride(from: span - 1, through: 0, by: -1) {
        guard let date = calendar.date(byAdding: .day, value: -index, to: today) else { continue }
        let phase = Double(span - 1 - index)
        let recovery = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let restingHR = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: formatter.string(from: date),
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 110,
            lightMin: 200,
            disturbances: 6,
            restingHr: gap ? nil : Int(restingHR.rounded()),
            avgHrv: gap ? nil : max(15, hrv),
            recovery: gap ? nil : max(2, min(99, recovery)),
            strain: gap ? nil : max(0, min(21, strain)),
            exerciseCount: 1
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
