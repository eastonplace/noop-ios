import Foundation
import StrandAnalytics
import WhoopStore

/// Freshness of a dated health value relative to the selected day.
enum DatedHealthMetricFreshness: Equatable, Sendable {
    case current
    case recent
}

/// One resolved daily metric with enough provenance for a UI surface to avoid mixing
/// a value from one day with a rail or caption from another day.
struct DatedHealthMetricValue: Equatable, Sendable {
    let day: String
    let ageDays: Int
    let value: Double
    let source: DailyMetricSource
    let freshness: DatedHealthMetricFreshness
}

/// One immutable selection for a skin-temperature surface. Current value, provenance,
/// sparkline identity, and rail history are resolved from the same row scan.
struct DatedHealthMetricPresentation: Equatable, Sendable {
    let current: DatedHealthMetricValue
    let history: [Double]
}

/// Resolves the newest recent skin-temperature daily value without changing conversion
/// or analysis rules. Imported WHOOP data wins over computed data for the same day; local
/// cache remains a preview/test fallback. Apple Health is intentionally not a skin-temp source.
enum DatedHealthMetricResolver {
    static let defaultMaximumAgeDays = 7

    static func skinTemperaturePresentation(
        rows: [SourcedDailyMetric],
        targetDay: String,
        maximumAgeDays: Int = defaultMaximumAgeDays,
        window: Int = 14
    ) -> DatedHealthMetricPresentation? {
        guard maximumAgeDays >= 0, window > 0 else { return nil }
        let points = resolvedSkinPoints(rows: rows, through: targetDay)
        guard let point = points.last else { return nil }
        let age = dayDistance(from: point.day, to: targetDay)
        guard age >= 0, age <= maximumAgeDays else { return nil }

        let current = DatedHealthMetricValue(
            day: point.day,
            ageDays: age,
            value: point.value,
            source: point.source,
            freshness: age == 0 ? .current : .recent
        )
        let absolute = VitalBands.isAbsoluteSkinTemp(point.value)
        let history = points
            .filter { VitalBands.isAbsoluteSkinTemp($0.value) == absolute }
            .suffix(window)
            .map(\.value)
        return DatedHealthMetricPresentation(current: current, history: history)
    }

    static func skinTemperature(
        rows: [SourcedDailyMetric],
        targetDay: String,
        maximumAgeDays: Int = defaultMaximumAgeDays
    ) -> DatedHealthMetricValue? {
        skinTemperaturePresentation(
            rows: rows,
            targetDay: targetDay,
            maximumAgeDays: maximumAgeDays
        )?.current
    }

    /// The same resolved identity as `skinTemperature`, expanded into a trail for legacy
    /// callers. Today uses `skinTemperaturePresentation` so it scans and selects only once.
    static func skinTemperatureHistory(
        rows: [SourcedDailyMetric],
        targetDay: String,
        window: Int = 14
    ) -> [Double] {
        guard window > 0 else { return [] }
        let points = resolvedSkinPoints(rows: rows, through: targetDay)
        guard let latest = points.last else { return [] }
        let absolute = VitalBands.isAbsoluteSkinTemp(latest.value)
        return points
            .filter { VitalBands.isAbsoluteSkinTemp($0.value) == absolute }
            .suffix(window)
            .map(\.value)
    }

    private struct SkinPoint: Equatable {
        let day: String
        let value: Double
        let source: DailyMetricSource
    }

    private static func resolvedSkinPoints(
        rows: [SourcedDailyMetric],
        through targetDay: String
    ) -> [SkinPoint] {
        let sourceOrder: [DailyMetricSource] = [.whoopImport, .noopComputed, .localCache]
        var byDay: [String: SkinPoint] = [:]
        for source in sourceOrder {
            for row in rows where row.source == source && row.metric.day <= targetDay {
                guard let value = row.metric.skinTempDevC,
                      value.isFinite,
                      (-20...60).contains(value),
                      byDay[row.metric.day] == nil else { continue }
                byDay[row.metric.day] = SkinPoint(
                    day: row.metric.day,
                    value: value,
                    source: source
                )
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func dayDistance(from earlier: String, to later: String) -> Int {
        guard let start = dayFormatter.date(from: earlier),
              let end = dayFormatter.date(from: later) else {
            return Int.max
        }
        return dayCalendar.dateComponents([.day], from: start, to: end).day ?? Int.max
    }

    private static let dayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
