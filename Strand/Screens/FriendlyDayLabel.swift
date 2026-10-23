import Foundation

/// A stored `yyyy-MM-dd` day key, written the way people say it. Raw keys never reach the screen.
enum FriendlyDayLabel {
    /// "Today", "Yesterday", or "Wed, Oct 21". A key that is not a real day reads as "this day" rather than showing
    /// the raw text.
    static func label(forDayKey key: String, today: String = Repository.localDayKey(Date())) -> String {
        guard let day = ExploreDayKey.dayNumber(for: key) else { return String(localized: "this day") }
        if let current = ExploreDayKey.dayNumber(for: today) {
            if day == current { return String(localized: "Today") }
            if day == current - 1 { return String(localized: "Yesterday") }
        }
        guard let date = ExploreDayKey.date(for: key) else { return String(localized: "this day") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
