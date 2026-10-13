import Foundation

/// The day the app calls "today": the local calendar day, except that it rolls at 04:00 rather than at midnight,
/// so between midnight and 04:00 "today" is still the day that started the evening before. The app's
/// `Repository.logicalDayRolloverHour` is the same hour; a test pins the two together, because this is the one
/// copy the widget extension can reach.
public enum WidgetLogicalDay {
    public static let rolloverHour = 4

    /// `yyyy-MM-dd` of the logical day `date` falls in, in `calendar`'s zone.
    public static func key(of date: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date)
        let logical = calendar.component(.hour, from: date) < rolloverHour
            ? calendar.date(byAdding: .day, value: -1, to: start) ?? start
            : start
        let year = calendar.component(.year, from: logical)
        let month = calendar.component(.month, from: logical)
        let day = calendar.component(.day, from: logical)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension WidgetLogicalDay {
    /// True when both instants fall in the same logical day.
    public static func isSameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar = .current) -> Bool {
        key(of: lhs, calendar: calendar) == key(of: rhs, calendar: calendar)
    }

    /// Whole logical days from `earlier` to `later`: 0 within one logical day, 1 across a 04:00 rollover.
    public static func daysBetween(_ earlier: Date, _ later: Date, calendar: Calendar = .current) -> Int {
        func logicalStart(_ date: Date) -> Date {
            let start = calendar.startOfDay(for: date)
            return calendar.component(.hour, from: date) < rolloverHour
                ? calendar.date(byAdding: .day, value: -1, to: start) ?? start
                : start
        }
        return calendar.dateComponents([.day], from: logicalStart(earlier), to: logicalStart(later)).day ?? 0
    }

    /// The next 04:00 wall-clock instant strictly after `date`, when the logical day rolls.
    public static func nextRollover(after date: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: rolloverHour, minute: 0, second: 0),
            matchingPolicy: .nextTime)
    }

    /// The instants a widget timeline needs an entry for: now, and the next rollover. A day-gated view decides
    /// at its entry's date, and WidgetKit does not reload at 04:00 on its own, so without the second entry the
    /// last day's figures stay on screen until some later reload.
    public static func timelineDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        [now] + (nextRollover(after: now, calendar: calendar).map { [$0] } ?? [])
    }
}

/// When the Stress widget may draw the hourly stress strip a snapshot carries.
///
/// The strip is one logical day's hours, so the only way it can be wrong is by being a different day's. The app
/// only writes a strip into a core committed on the strip's own logical day (it neither computes nor carries one
/// for a day that is behind), so the day the core was last committed on is the day the strip describes. That is
/// the whole rule: that commit must be on today's logical day. An age limit on top of it is not a freshness
/// test, because an hour without a strap sync (the phone locked, the strap out of range) leaves the strip's
/// hours as true as they were. The strip ends at the last scored hour, so a stale tail is visible, not hidden.
///
/// The days are logical days, not calendar days. A strip committed at 23:30 is still today's at 01:00, and one
/// committed at 02:30 belongs to the day before and is not today's at 10:00.
public enum WidgetStressFreshness {
    public static func isCurrent(updated: Date, now: Date, calendar: Calendar = .current) -> Bool {
        WidgetLogicalDay.key(of: updated, calendar: calendar) == WidgetLogicalDay.key(of: now, calendar: calendar)
    }
}
