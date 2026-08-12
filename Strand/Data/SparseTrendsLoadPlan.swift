import Foundation
import NoopPhase34Core
import WhoopStore

public enum SparseTrendsLoadPlan {
    public static func windows(
        anchorDay: CivilDay,
        timeZoneIdentifier: String,
        rangeDays requestedRangeDays: Int,
        weekOffset requestedWeekOffset: Int,
        weeklyBaselineWeeks: Int = 8,
        heatmapMinimumDays: Int = 42
    ) throws -> [CanonicalHealthSurfaceReadWindow] {
        let healthCalendar = try HealthCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
        let rangeDays = TrendsBounds.clampRangeDays(requestedRangeDays)
        let weekOffset = TrendsBounds.clampWeekOffset(requestedWeekOffset)

        var dayRanges: [(first: CivilDay, last: CivilDay)] = []

        // Current chart plus equal previous comparison period.
        let chartFirst = try healthCalendar.adding(
            days: -(rangeDays - 1),
            to: anchorDay
        )
        let previousLast = try healthCalendar.adding(days: -1, to: chartFirst)
        let previousFirst = try healthCalendar.adding(
            days: -(rangeDays - 1),
            to: previousLast
        )
        dayRanges.append((previousFirst, anchorDay))

        // Current heat-map minimum near the visible anchor.
        let heatmapFirst = try healthCalendar.adding(
            days: -(max(1, heatmapMinimumDays) - 1),
            to: anchorDay
        )
        dayRanges.append((heatmapFirst, anchorDay))

        // Weekly review is a separate sparse window. The digest consumes the
        // requested baseline weeks plus the immediately-prior comparison week,
        // followed by the selected week itself.
        let selectedWeekAnchor = try healthCalendar.adding(
            days: weekOffset * 7,
            to: anchorDay
        )
        let selectedWeekStart = try monday(
            containing: selectedWeekAnchor,
            healthCalendar: healthCalendar,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let selectedWeekEnd = try healthCalendar.adding(days: 6, to: selectedWeekStart)
        let baselineAndComparisonWeeks = max(1, weeklyBaselineWeeks) + 1
        let baselineStart = try healthCalendar.adding(
            days: -(baselineAndComparisonWeeks * 7),
            to: selectedWeekStart
        )
        dayRanges.append((baselineStart, selectedWeekEnd))

        let coalesced = try coalesce(
            dayRanges,
            healthCalendar: healthCalendar
        )
        return try coalesced.map { range in
            let firstInterval = try healthCalendar.interval(for: range.first)
            let lastInterval = try healthCalendar.interval(for: range.last)
            return CanonicalHealthSurfaceReadWindow(
                fromDay: range.first.key,
                throughDay: range.last.key,
                sleepFromTs: Int(firstInterval.start.timeIntervalSince1970) - 20 * 3_600,
                sleepThroughTs: Int(lastInterval.end.timeIntervalSince1970) + 4 * 3_600
            )
        }
    }

    private static func monday(
        containing day: CivilDay,
        healthCalendar: HealthCalendar,
        timeZoneIdentifier: String
    ) throws -> CivilDay {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw SparseTrendsLoadPlanError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try day.date(in: calendar)
        let weekday = calendar.component(.weekday, from: start)
        // Calendar weekday: Sunday=1, Monday=2 ... Saturday=7.
        let daysSinceMonday = (weekday + 5) % 7
        return try healthCalendar.adding(days: -daysSinceMonday, to: day)
    }

    private static func coalesce(
        _ ranges: [(first: CivilDay, last: CivilDay)],
        healthCalendar: HealthCalendar
    ) throws -> [(first: CivilDay, last: CivilDay)] {
        let sorted = ranges.sorted {
            ($0.first, $0.last) < ($1.first, $1.last)
        }
        guard var current = sorted.first else { return [] }
        var result: [(first: CivilDay, last: CivilDay)] = []
        for range in sorted.dropFirst() {
            let nextAfterCurrent = try healthCalendar.adding(days: 1, to: current.last)
            if range.first <= nextAfterCurrent {
                current.last = max(current.last, range.last)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}

public enum SparseTrendsLoadPlanError: Error {
    case invalidTimeZone
}
