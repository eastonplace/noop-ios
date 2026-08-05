import Foundation
import NoopPhase34Core
import WhoopStore

/// Plans the single WAL read used by historical verification. It contains the
/// exact changed-day windows and a small current Today window. A January repair
/// therefore cannot rebuild August Today from an August-shaped empty read.
@MainActor
enum RepositoryHistoricalSnapshotWindows {
    static func make(
        analyzedDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String,
        template: TodayHealthSnapshot,
        now: Date
    ) throws -> [CanonicalHealthSurfaceReadWindow] {
        let recorded = try HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier)
        let currentTimeZone = TimeZone.autoupdatingCurrent
        var currentCalendar = Calendar(identifier: .gregorian)
        currentCalendar.timeZone = currentTimeZone

        var windows: [CanonicalHealthSurfaceReadWindow] = []
        let sorted = analyzedDays.sorted()
        var run: [CivilDay] = []
        func appendRun(_ run: [CivilDay]) throws {
            guard let first = run.first, let last = run.last else { return }
            let firstInterval = try recorded.interval(for: first)
            let lastInterval = try recorded.interval(for: last)
            windows.append(CanonicalHealthSurfaceReadWindow(
                fromDay: first.key,
                throughDay: last.key,
                sleepFromTs: Int(firstInterval.start.timeIntervalSince1970) - 20 * 3_600,
                sleepThroughTs: Int(lastInterval.end.timeIntervalSince1970) + 4 * 3_600
            ))
        }
        for day in sorted {
            if let previous = run.last,
               (try? recorded.adding(days: 1, to: previous)) != day {
                try appendRun(run)
                run.removeAll(keepingCapacity: true)
            }
            run.append(day)
        }
        try appendRun(run)

        var currentKeys = Set([
            template.displayDay,
            template.logicalDay,
            template.localDay,
            Repository.logicalDayKey(now, calendar: currentCalendar),
            Repository.localDayKey(now, calendar: currentCalendar),
        ])
        currentKeys = currentKeys.filter { $0.count == 10 }
        if let firstKey = currentKeys.min(), let lastKey = currentKeys.max(),
           let first = try? CivilDay(key: firstKey), let last = try? CivilDay(key: lastKey) {
            let firstInterval = try HealthCalendar(timeZoneIdentifier: currentTimeZone.identifier).interval(for: first)
            let lastInterval = try HealthCalendar(timeZoneIdentifier: currentTimeZone.identifier).interval(for: last)
            windows.append(CanonicalHealthSurfaceReadWindow(
                fromDay: first.key,
                throughDay: last.key,
                sleepFromTs: Int(firstInterval.start.timeIntervalSince1970) - 20 * 3_600,
                sleepThroughTs: Int(lastInterval.end.timeIntervalSince1970) + 4 * 3_600
            ))
        }
        return windows
    }
}
