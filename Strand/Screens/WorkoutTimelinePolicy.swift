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

struct WorkoutTimelineGroup: Sendable, Equatable, Identifiable {
    let day: Date
    let ids: [String]
    var id: Date { day }
}

/// A display projection of existing workout facts. This never writes history or substitutes duration estimates.
enum WorkoutTimelinePolicy {
    static func groups(items: [WorkoutTimelineItem], calendar: Calendar = .autoupdatingCurrent) -> [WorkoutTimelineGroup] {
        let grouped = Dictionary(grouping: unique(items), by: { calendar.startOfDay(for: $0.start) })
        return grouped.keys.sorted(by: >).map { day in
            WorkoutTimelineGroup(day: day, ids: (grouped[day] ?? []).map(\.id))
        }
    }

    static func week(items: [WorkoutTimelineItem], through end: Date,
                     calendar: Calendar = .autoupdatingCurrent) -> [WorkoutTimelineDay] {
        guard end.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let endDay = calendar.startOfDay(for: end)
        let grouped = Dictionary(grouping: unique(items), by: { calendar.startOfDay(for: $0.start) })
        return (-6...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: endDay) else { return nil }
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

    private static func unique(_ items: [WorkoutTimelineItem]) -> [WorkoutTimelineItem] {
        var seen = Set<String>()
        return items.filter { $0.start.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
            .filter { seen.insert($0.id).inserted }
    }
}
