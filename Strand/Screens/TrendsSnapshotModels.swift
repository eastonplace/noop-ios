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
/// Latest, period delta, reliability, and compact spark all share one finite, chronological source.
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
        let finiteSeries = Self.finiteChronological(series)
        let finitePreviousSeries = Self.finiteChronological(previousSeries)
        source = finiteSeries
        latest = finiteSeries.last?.value
        let currentMean = Self.mean(finiteSeries)
        let previousMean = Self.mean(finitePreviousSeries)
        delta = currentMean.flatMap { current in previousMean.map { current - $0 } }
        spark = TrendPointExtremaSampler.sample(finiteSeries, maximumCount: 30)
        currentCount = finiteSeries.count
        previousCount = finitePreviousSeries.count
        self.expectedCount = max(1, expectedCount)
        let minimum = max(3, Int(ceil(Double(self.expectedCount) * 0.2)))
        comparisonIsReliable = finiteSeries.count >= minimum && finitePreviousSeries.count >= minimum

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

    private static func finiteChronological(_ series: [TrendPoint]) -> [TrendPoint] {
        series
            .filter {
                $0.value.isFinite && $0.date.timeIntervalSinceReferenceDate.isFinite
            }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.value < rhs.value }
                return lhs.date < rhs.date
            }
    }

    private static func mean(_ series: [TrendPoint]) -> Double? {
        guard !series.isEmpty else { return nil }
        return series.reduce(0) { $0 + $1.value } / Double(series.count)
    }
}

struct PaperTrendSeries: Sendable {
    let recovery: [TrendPoint]
    let strain: [TrendPoint]
    let sleep: [TrendPoint]
    let hrv: [TrendPoint]

    static func build(days: [DailyMetric], sleepByDay: [String: Double],
                      date: (String) -> Date?) -> PaperTrendSeries {
        PaperTrendSeries(
            recovery: days.compactMap { day in
                guard let value = day.recovery, value.isFinite,
                      let date = date(day.day), date.timeIntervalSinceReferenceDate.isFinite
                else { return nil }
                return TrendPoint(date: date, value: value)
            },
            strain: days.compactMap { day in
                guard let stored = day.strain, stored.isFinite,
                      let date = date(day.day), date.timeIntervalSinceReferenceDate.isFinite
                else { return nil }
                let value = StrainScale.displayValue(fromStored: stored)
                return value.isFinite ? TrendPoint(date: date, value: value) : nil
            },
            sleep: days.compactMap { day in
                guard let value = sleepByDay[day.day], value.isFinite,
                      let date = date(day.day), date.timeIntervalSinceReferenceDate.isFinite
                else { return nil }
                return TrendPoint(date: date, value: value)
            },
            hrv: days.compactMap { day in
                guard let value = day.avgHrv, value.isFinite,
                      let date = date(day.day), date.timeIntervalSinceReferenceDate.isFinite
                else { return nil }
                return TrendPoint(date: date, value: value)
            }
        )
    }
}

enum ProductionTrendMetric: String, CaseIterable, Identifiable, Sendable {
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
        guard value.isFinite else { return "—" }
        switch self {
        case .strain, .sleepDuration, .respiratory, .skinTemp, .stress:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .steps, .calories:
            return Int(value.rounded()).formatted()
        default:
            return "\(Int(value.rounded()))"
        }
    }

    func formatWithUnit(_ value: Double) -> String {
        let rendered = format(value)
        guard rendered != "—", !unit.isEmpty else { return rendered }
        return unit == "%" ? "\(rendered)%" : "\(rendered) \(unit)"
    }
}

struct TrendsScreenSnapshotKey: Hashable, Sendable {
    let revision: Int
    let anchorDay: String
    let timeZoneIdentifier: String
    let metric: String
    let range: String
    let weekOffset: Int
}

struct TrendsScreenSnapshot: Sendable {
    let key: TrendsScreenSnapshotKey
    let currentSeries: PaperTrendSeries
    let previousSeries: PaperTrendSeries
    let selectedCalendarDays: [CalendarMetricDay]
    let selectedPoints: [TrendPoint]
    let selectedDateDomain: ClosedRange<Date>
    let heatDays: [CalendarMetricDay]
    let weekdayAverages: [Double?]
    let baseline: Double
    let typical: ClosedRange<Double>
    let weeklyDigest: WeeklyDigest
    let minimumWeekOffset: Int

    nonisolated static func build(
        key: TrendsScreenSnapshotKey,
        data: TrendsLoadedData,
        metric: ProductionTrendMetric,
        range: TrendRange,
        weekOffset: Int,
        referenceDate: Date,
        calendar inputCalendar: Calendar,
        effortDisplayFactor: Double
    ) -> TrendsScreenSnapshot? {
        guard !Task.isCancelled,
              referenceDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var calendar = inputCalendar
        calendar.timeZone = TimeZone(identifier: data.timeZoneIdentifier) ?? inputCalendar.timeZone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        func days(periodOffset: Int) -> [DailyMetric] {
            guard let period = TrendCalendar.equalLengthPeriod(
                through: referenceDate,
                count: range.days,
                periodOffset: periodOffset,
                calendar: calendar
            ) else { return [] }
            return (0..<range.days).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: period.lowerBound)
                else { return nil }
                return data.canonicalByDay[formatter.string(from: date)]
            }
        }

        let currentDays = days(periodOffset: 0)
        let previousDays = days(periodOffset: -1)
        let currentSeries = PaperTrendSeries.build(
            days: currentDays,
            sleepByDay: data.sleepPerfByDay,
            date: { calendar.date(from: Self.components(for: $0)) }
        )
        let previousSeries = PaperTrendSeries.build(
            days: previousDays,
            sleepByDay: data.sleepPerfByDay,
            date: { calendar.date(from: Self.components(for: $0)) }
        )

        let observationCount = max(range.days, 35)
        let observations: [CalendarMetricDay] = (0..<observationCount).compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset - (observationCount - 1),
                to: referenceDate
            ), date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let key = formatter.string(from: date)
            return CalendarMetricDay(
                date: calendar.startOfDay(for: date),
                value: data.canonicalByDay[key].flatMap {
                    value(for: metric, day: $0, data: data)
                }
            )
        }
        guard !Task.isCancelled else { return nil }

        let selectedCalendarDays = Array(observations.suffix(range.days))
        let selectedPoints = selectedCalendarDays.compactMap { day in
            guard day.date.timeIntervalSinceReferenceDate.isFinite,
                  let value = finite(day.value) else { return nil }
            return TrendPoint(date: day.date, value: value)
        }
        let dateDomain = TrendCalendar.dateDomain(
            through: referenceDate,
            count: range.days,
            calendar: calendar
        ) ?? referenceDate...referenceDate
        let heatDays = TrendCalendar.buildFiveWeekWindow(
            observations: observations,
            through: referenceDate,
            calendar: calendar
        )
        let weekdayAverages = TrendCalendar.weekdayAverages(selectedCalendarDays, calendar: calendar)
            .map(finite)
        let values = selectedPoints.map(\.value)
        let baseline = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let spread: Double = {
            guard values.count > 1 else { return max(abs(baseline) * 0.1, 1) }
            let variance = values.reduce(0) { $0 + pow($1 - baseline, 2) } / Double(values.count)
            return max(sqrt(variance), abs(baseline) * 0.04)
        }()

        let weekAnchorDay = WeeklyDigestEngine.addDays(data.anchorDay, weekOffset * 7)
        let digestDays: [DailyMetric]
        if let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) {
            let first = WeeklyDigestEngine.addDays(
                monday,
                -7 * (WeeklyDigestEngine.baselineWeeks + 1)
            )
            digestDays = (0..<(7 * (WeeklyDigestEngine.baselineWeeks + 2))).compactMap { offset in
                data.canonicalByDay[WeeklyDigestEngine.addDays(first, offset)]
            }.filter(Self.hasFiniteDigestInputs)
        } else {
            digestDays = []
        }
        let digest = WeeklyDigestSource.digest(
            from: digestDays,
            anchorDay: weekAnchorDay,
            sleepByDay: data.sleepPerfByDay.filter { $0.value.isFinite },
            effortDisplayFactor: effortDisplayFactor.isFinite ? effortDisplayFactor : 1
        )

        let minimumWeekOffset: Int = {
            guard let earliest = data.canonicalDays.first?.day,
                  let earliestMonday = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
                  let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: data.anchorDay),
                  let earliestDate = calendar.date(from: Self.components(for: earliestMonday)),
                  let thisDate = calendar.date(from: Self.components(for: thisMonday))
            else { return 0 }
            let days = calendar.dateComponents([.day], from: earliestDate, to: thisDate).day ?? 0
            return -min(520, max(0, days / 7))
        }()

        return TrendsScreenSnapshot(
            key: key,
            currentSeries: currentSeries,
            previousSeries: previousSeries,
            selectedCalendarDays: selectedCalendarDays,
            selectedPoints: selectedPoints,
            selectedDateDomain: dateDomain,
            heatDays: heatDays,
            weekdayAverages: weekdayAverages,
            baseline: baseline,
            typical: (baseline - max(spread, 0.5))...(baseline + max(spread, 0.5)),
            weeklyDigest: digest,
            minimumWeekOffset: minimumWeekOffset
        )
    }

    private static func components(for day: String) -> DateComponents {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return DateComponents() }
        return DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
    }

    private static func hasFiniteDigestInputs(_ day: DailyMetric) -> Bool {
        [day.totalSleepMin, day.avgHrv, day.recovery, day.strain]
            .compactMap { $0 }
            .allSatisfy(\.isFinite)
    }

    private static func value(
        for metric: ProductionTrendMetric,
        day: DailyMetric,
        data: TrendsLoadedData
    ) -> Double? {
        switch metric {
        case .recovery: finite(day.recovery)
        case .strain: finite(day.strain.map(StrainScale.displayValue(fromStored:)))
        case .sleepPerformance: finite(data.sleepPerfByDay[day.day])
        case .sleepDuration: finite(day.totalSleepMin.map { $0 / 60 })
        case .hrv: finite(day.avgHrv)
        case .restingHR: finite(day.restingHr.map(Double.init))
        case .respiratory: finite(day.respRateBpm)
        case .spo2: finite(day.spo2Pct)
        case .skinTemp: finite(day.skinTempDevC)
        case .steps:
            finite(day.steps.map(Double.init) ?? data.appleByDay[day.day]?.steps.map(Double.init))
        case .calories:
            finite(day.activeKcalEst ?? data.appleByDay[day.day]?.activeKcal)
        case .stress: finite(data.stressByDay[day.day])
        }
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }
}

enum TrendsSnapshotHandoff {
    nonisolated static func accepts(
        snapshotKey: TrendsScreenSnapshotKey?,
        currentKey: TrendsScreenSnapshotKey
    ) -> Bool {
        snapshotKey == currentKey
    }

    nonisolated static func current(
        _ snapshot: TrendsScreenSnapshot?,
        for key: TrendsScreenSnapshotKey
    ) -> TrendsScreenSnapshot? {
        guard accepts(snapshotKey: snapshot?.key, currentKey: key) else { return nil }
        return snapshot
    }
}
