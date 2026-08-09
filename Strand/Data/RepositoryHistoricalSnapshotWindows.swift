import Foundation
import NoopPhase34Core
import WhoopStore

/// Plans bounded exact historical windows plus a small current Today window. Sparse historical work remains
/// sparse; only overlapping or adjacent padded windows are coalesced.
@MainActor
enum RepositoryHistoricalWindowPlanner {
    static let maximumExactDayCount = HistoricalAnalysisWork.maximumExactDayCount
    static let maximumTemplateDistanceFromNow = 2

    static func make(
        analyzedDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String,
        template: TodayHealthSnapshot,
        now: Date
    ) throws -> [CanonicalHealthSurfaceReadWindow] {
        guard !analyzedDays.isEmpty,
              analyzedDays.count <= maximumExactDayCount else {
            throw RepositoryHistoricalWindowPlannerError.invalidExactScope
        }

        let recorded = try HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier)
        let currentZone = TimeZone.autoupdatingCurrent
        let current = try HealthCalendar(timeZoneIdentifier: currentZone.identifier)
        var currentCalendar = Calendar(identifier: .gregorian)
        currentCalendar.timeZone = currentZone
        let currentCivil = try current.civilDay(containing: now)
        let currentLogical = try current.physiologicalDay(containing: now)

        // Widget Recovery delta is part of the immutable verified generation. Include the prior logical
        // day in this same WAL read so delivery never consults a later mutable Repository cache.
        let previousLogical = try current.adding(days: -1, to: currentLogical)
        var currentDays: Set<CivilDay> = [currentCivil, currentLogical, previousLogical]
        for key in [template.displayDay, template.logicalDay, template.localDay] {
            guard let day = try? CivilDay(key: key),
                  let distance = try? absoluteDayDistance(
                      from: day, to: currentCivil, calendar: currentCalendar),
                  distance <= maximumTemplateDistanceFromNow else { continue }
            currentDays.insert(day)
            currentDays.insert(try current.adding(days: -1, to: day))
        }

        var windows = try windowsForRuns(
            days: analyzedDays,
            calendar: recorded,
            sleepLookbackSeconds: 20 * 3_600,
            sleepLookaheadSeconds: 4 * 3_600)
        windows += try windowsForRuns(
            days: currentDays,
            calendar: current,
            sleepLookbackSeconds: 20 * 3_600,
            sleepLookaheadSeconds: 4 * 3_600)
        return coalesced(windows)
    }

    private static func windowsForRuns(
        days: Set<CivilDay>,
        calendar: HealthCalendar,
        sleepLookbackSeconds: Int,
        sleepLookaheadSeconds: Int
    ) throws -> [CanonicalHealthSurfaceReadWindow] {
        let sorted = days.sorted()
        guard var first = sorted.first else { return [] }
        var last = first
        var result: [CanonicalHealthSurfaceReadWindow] = []

        func append(_ first: CivilDay, _ last: CivilDay) throws {
            let firstInterval = try calendar.interval(for: first)
            let lastInterval = try calendar.interval(for: last)
            result.append(CanonicalHealthSurfaceReadWindow(
                fromDay: first.key,
                throughDay: last.key,
                sleepFromTs: Int(firstInterval.start.timeIntervalSince1970) - sleepLookbackSeconds,
                sleepThroughTs: Int(lastInterval.end.timeIntervalSince1970) + sleepLookaheadSeconds))
        }

        for day in sorted.dropFirst() {
            if try calendar.adding(days: 1, to: last) == day {
                last = day
            } else {
                try append(first, last)
                first = day
                last = day
            }
        }
        try append(first, last)
        return result
    }

    static func coalesced(
        _ windows: [CanonicalHealthSurfaceReadWindow]
    ) -> [CanonicalHealthSurfaceReadWindow] {
        let sorted = windows.sorted {
            ($0.fromDay, $0.throughDay, $0.sleepFromTs, $0.sleepThroughTs)
                < ($1.fromDay, $1.throughDay, $1.sleepFromTs, $1.sleepThroughTs)
        }
        guard var current = sorted.first else { return [] }
        var result: [CanonicalHealthSurfaceReadWindow] = []
        for next in sorted.dropFirst() {
            let dayRangesTouch = next.fromDay <= dayAfter(current.throughDay)
            let sleepRangesOverlap = next.sleepFromTs <= current.sleepThroughTs
            if dayRangesTouch && sleepRangesOverlap {
                current = CanonicalHealthSurfaceReadWindow(
                    fromDay: min(current.fromDay, next.fromDay),
                    throughDay: max(current.throughDay, next.throughDay),
                    sleepFromTs: min(current.sleepFromTs, next.sleepFromTs),
                    sleepThroughTs: max(current.sleepThroughTs, next.sleepThroughTs))
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func dayAfter(_ key: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let day = try? CivilDay(key: key),
              let date = try? day.date(in: calendar) else { return key }
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return key }
        let components = calendar.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func absoluteDayDistance(
        from lhs: CivilDay,
        to rhs: CivilDay,
        calendar: Calendar
    ) throws -> Int {
        let lhsDate = try lhs.date(in: calendar)
        let rhsDate = try rhs.date(in: calendar)
        let value = calendar.dateComponents([.day], from: lhsDate, to: rhsDate).day ?? .max
        return value == .min ? .max : abs(value)
    }
}

typealias RepositoryHistoricalSnapshotWindows = RepositoryHistoricalWindowPlanner

enum RepositoryHistoricalWindowPlannerError: Error {
    case invalidExactScope
}
