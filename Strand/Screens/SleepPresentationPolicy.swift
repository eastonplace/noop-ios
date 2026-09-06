import Foundation

/// Calendar-day selection shared by missing-night routing and duration history.
enum SleepPresentationPolicy {
    static func isMissingCurrentNight(wakeDates: [Date], now: Date, calendar: Calendar = .current) -> Bool {
        !wakeDates.contains { calendar.isDate($0, inSameDayAs: now) }
    }

    static func containsInRecentWindow(_ date: Date, now: Date, days: Int = 30,
                                       calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
        return date >= start && date < end
    }
}
