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
        delta = currentMean.flatMap { current in
            previousMean.flatMap { previous in
                let candidate = current - previous
                return candidate.isFinite ? candidate : nil
            }
        }
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
        let scale = series.reduce(0.0) { max($0, abs($1.value)) }
        guard scale.isFinite, scale > 0 else { return 0 }
        var mean = 0.0
        for (index, point) in series.enumerated() {
            let value = point.value / scale
            mean += (value - mean) / Double(index + 1)
        }
        let result = mean * scale
        return result.isFinite ? result : nil
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
            return value.formatted(.number.precision(.fractionLength(0)))
        default:
            return value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    func formatWithUnit(_ value: Double) -> String {
        let rendered = format(value)
        guard rendered != "—", !unit.isEmpty else { return rendered }
        return unit == "%" ? "\(rendered)%" : "\(rendered) \(unit)"
    }

    /// Imported database rows are untrusted display input. Keep corrupt but finite
    /// values out of chart geometry as well as formatters.
    func acceptsForDisplay(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .recovery, .sleepPerformance, .spo2: return (0...100).contains(value)
        case .strain, .stress: return (0...100).contains(value)
        case .sleepDuration: return (0...24).contains(value)
        case .hrv: return (0...2_000).contains(value)
        case .restingHR: return (20...300).contains(value)
        case .respiratory: return (4...80).contains(value)
        case .skinTemp: return (-20...20).contains(value)
        case .steps: return (0...2_000_000).contains(value)
        case .calories: return (0...100_000).contains(value)
        }
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
        let selectedPoints: [TrendPoint] = selectedCalendarDays.compactMap { day in
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
        let baseline = stableMean(values) ?? 0
        let spread = stableSpread(values, around: baseline)

        let weekAnchorDay = WeeklyDigestEngine.addDays(data.anchorDay, weekOffset * 7)
        let digestDays: [DailyMetric]
        if let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) {
            let first = WeeklyDigestEngine.addDays(
                monday,
                -7 * (WeeklyDigestEngine.baselineWeeks + 1)
            )
            digestDays = (0..<(7 * (WeeklyDigestEngine.baselineWeeks + 2))).compactMap { offset in
                data.canonicalByDay[WeeklyDigestEngine.addDays(first, offset)]
            }
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
            typical: finiteTypical(center: baseline, spread: spread),
            weeklyDigest: digest,
            minimumWeekOffset: minimumWeekOffset
        )
    }

    private static func components(for day: String) -> DateComponents {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return DateComponents() }
        return DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
    }

    private static func stableMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let scale = values.reduce(0.0) { max($0, abs($1)) }
        guard scale.isFinite else { return nil }
        guard scale > 0 else { return 0 }
        var mean = 0.0
        for (index, value) in values.enumerated() {
            let normalised = value / scale
            mean += (normalised - mean) / Double(index + 1)
        }
        let result = mean * scale
        return result.isFinite ? result : nil
    }

    private static func stableSpread(_ values: [Double], around baseline: Double) -> Double {
        guard values.count > 1, baseline.isFinite else {
            return max(abs(baseline) * 0.1, 1)
        }
        let scale = values.reduce(0.0) { max($0, abs($1)) }
        guard scale.isFinite, scale > 0 else { return 1 }
        let center = baseline / scale
        var meanSquares = 0.0
        for (index, value) in values.enumerated() {
            let delta = value / scale - center
            let square = delta * delta
            meanSquares += (square - meanSquares) / Double(index + 1)
        }
        let scaled = sqrt(max(0, meanSquares)) * scale
        let result = max(scaled, abs(baseline) * 0.04, 0.5)
        return result.isFinite ? result : Double.greatestFiniteMagnitude
    }

    private static func finiteTypical(center: Double, spread: Double) -> ClosedRange<Double> {
        guard center.isFinite, spread.isFinite else { return -1...1 }
        let lowerCandidate = center - spread
        let upperCandidate = center + spread
        let lower = lowerCandidate.isFinite ? lowerCandidate : -Double.greatestFiniteMagnitude
        let upper = upperCandidate.isFinite ? upperCandidate : Double.greatestFiniteMagnitude
        guard lower <= upper else { return -1...1 }
        return lower...upper
    }

    private static func value(
        for metric: ProductionTrendMetric,
        day: DailyMetric,
        data: TrendsLoadedData
    ) -> Double? {
        let candidate: Double?
        switch metric {
        case .recovery: candidate = day.recovery
        case .strain: candidate = day.strain.map(StrainScale.displayValue(fromStored:))
        case .sleepPerformance: candidate = data.sleepPerfByDay[day.day]
        case .sleepDuration: candidate = day.totalSleepMin.map { $0 / 60 }
        case .hrv: candidate = day.avgHrv
        case .restingHR: candidate = day.restingHr.map(Double.init)
        case .respiratory: candidate = day.respRateBpm
        case .spo2: candidate = day.spo2Pct
        case .skinTemp: candidate = day.skinTempDevC
        case .steps: candidate = day.steps.map(Double.init) ?? data.appleByDay[day.day]?.steps.map(Double.init)
        case .calories: candidate = day.activeKcalEst ?? data.appleByDay[day.day]?.activeKcal
        case .stress: candidate = data.stressByDay[day.day]
        }
        guard let value = finite(candidate), metric.acceptsForDisplay(value) else { return nil }
        return value
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }
}

enum TrendsSnapshotHandoff {
    nonisolated static func canonicalDays(
        loaded: TrendsLoadedData,
        fallback: [DailyMetric]
    ) -> [DailyMetric] {
        loaded.revision < 0 ? fallback : loaded.canonicalDays
    }

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
