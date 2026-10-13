import Foundation

/// When the Stress widget may draw the hourly stress strip a snapshot carries.
///
/// The strip is one day's hours, so the only way it can be wrong is by being a different day's. That is the
/// whole rule: the snapshot must be from today. An age limit on top of it is not a freshness test. The core's
/// `updated` moves only when a new generation is published, which happens when the strap syncs, so an hour
/// without a sync (the phone locked, the strap out of range) blanked a strip whose hours were still true, while
/// the main widget draws the same strip with no age limit at all. The strip ends at the last scored hour, so a
/// stale tail is visible rather than hidden.
public enum WidgetStressFreshness {
    public static func isCurrent(updated: Date, now: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(updated, inSameDayAs: now)
    }
}
