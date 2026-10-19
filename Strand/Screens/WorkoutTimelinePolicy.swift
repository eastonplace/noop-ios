import Foundation

struct WorkoutTimelineItem: Sendable, Equatable {
    let id: String
    let start: Date
    let seconds: Double?
}

struct WorkoutTimelineDay: Sendable, Equatable, Identifiable {
    let day: Date
    let minutes: Double
    let sessions: Int
    let missingDurations: Int
    var id: Date { day }
    /// A day with recorded sessions but no valid duration remains a chart gap.
    var chartValue: Double? { sessions > 0 && sessions == missingDurations ? nil : minutes }
}

/// What a run of days adds up to.
struct WorkoutTimelineTotals: Sendable, Equatable {
    let minutes: Double
    let sessions: Int
    let missingDurations: Int
    /// The known minutes, or nil when nothing in the run has a known duration (no sessions, or only sessions without
    /// one), so a total that was never measured is not shown as zero.
    var knownMinutes: Double? { sessions > missingDurations ? minutes : nil }
}

struct WorkoutTimelineGroup: Sendable, Equatable, Identifiable {
    let day: Date
    let ids: [String]
    var id: Date { day }
}

/// A display projection of existing workout facts. This never writes history or substitutes duration estimates.
enum WorkoutTimelinePolicy {
    /// The history feed's day groups: one per local start day, newest day first, newest session first within a day,
    /// each id once.
    static func groups(items: [WorkoutTimelineItem], calendar: Calendar = .autoupdatingCurrent) -> [WorkoutTimelineGroup] {
        let grouped = Dictionary(grouping: unique(items), by: { calendar.startOfDay(for: $0.start) })
        return grouped.keys.sorted(by: >).map { day in
            WorkoutTimelineGroup(day: day, ids: (grouped[day] ?? []).map(\.id))
        }
    }

    /// The seven civil days ending on `end`'s day: from the first day's midnight to the midnight after the last.
    /// Nil for a date that is not finite.
    static func weekInterval(through end: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        let days = weekDays(through: end, calendar: calendar)
        guard let first = days.first, let last = days.last,
              let next = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        let after = calendar.startOfDay(for: next)
        guard after > first else { return nil }
        return DateInterval(start: first, end: after)
    }

    static func week(items: [WorkoutTimelineItem], through end: Date,
                     calendar: Calendar = .autoupdatingCurrent) -> [WorkoutTimelineDay] {
        let grouped = Dictionary(grouping: unique(items), by: { calendar.startOfDay(for: $0.start) })
        return weekDays(through: end, calendar: calendar).map { day in
            let rows = grouped[day] ?? []
            var total = 0.0
            var missing = 0
            for row in rows {
                guard let seconds = row.seconds, seconds.isFinite, seconds >= 0,
                      (total + seconds / 60).isFinite else { missing += 1; continue }
                total += seconds / 60
            }
            return WorkoutTimelineDay(day: day, minutes: total, sessions: rows.count, missingDurations: missing)
        }
    }

    /// The sum of `days`: known minutes, sessions, and the sessions whose duration is missing.
    static func totals(_ days: [WorkoutTimelineDay]) -> WorkoutTimelineTotals {
        WorkoutTimelineTotals(
            minutes: days.reduce(0) { $0 + $1.minutes },
            sessions: days.reduce(0) { $0 + $1.sessions },
            missingDurations: days.reduce(0) { $0 + $1.missingDurations })
    }

    /// Midnight of each of the seven days ending on `end`'s day, oldest first. Each day is snapped to its own
    /// midnight, so a daylight-saving change never shifts a day off the start-of-day keys the rows are grouped by.
    private static func weekDays(through end: Date, calendar: Calendar) -> [Date] {
        guard end.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let endDay = calendar.startOfDay(for: end)
        return (-6...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: endDay).map { calendar.startOfDay(for: $0) }
        }
    }

    private static func unique(_ items: [WorkoutTimelineItem]) -> [WorkoutTimelineItem] {
        var seen = Set<String>()
        return items.filter { $0.start.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
            .filter { seen.insert($0.id).inserted }
    }
}
