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
