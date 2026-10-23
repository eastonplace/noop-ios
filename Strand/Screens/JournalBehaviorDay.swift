import Foundation

/// The Journal asks about a behaviour day ("How was yesterday?") and stores it under the morning it affects: the
/// importer's wake-day convention, which What Moves You and Heads-Up already read. So the key for
/// "Yesterday" is today's own key, and "Today" is tomorrow's key. Nothing here changes what is stored; it only
/// turns a storage key into the words a person would use, and back.
///
/// Day keys are plain `yyyy-MM-dd` strings. Every step goes through `ExploreDayKey`'s integer day count, so a
/// month, year or leap-day boundary needs no calendar and cannot drift across a time-zone or DST change.
enum JournalBehaviorDay {
    /// A key moved by whole days, or nil when `key` is not a real day.
    static func shifted(_ key: String, by days: Int) -> String? {
        ExploreDayKey.dayNumber(for: key).map { ExploreDayKey.key(forDayNumber: $0 + days) }
    }

    /// The key that answers about the behaviour day `key` are stored under: the morning after it.
    static func storageKey(forBehaviorKey key: String) -> String? { shifted(key, by: 1) }

    /// The behaviour day a storage key describes: the day before that morning.
    static func behaviorKey(forStorageKey key: String) -> String? { shifted(key, by: -1) }

    /// The storage key for a behaviour day picked as a calendar date.
    static func storageKey(forBehaviorDate date: Date, calendar: Calendar = .current) -> String {
        Repository.localDayKey(calendar.date(byAdding: .day, value: 1, to: date) ?? date, calendar: calendar)
    }

    /// The behaviour day a storage key describes, as a date at the start of that day.
    static func behaviorDate(forStorageKey key: String, calendar: Calendar = .current) -> Date? {
        behaviorKey(forStorageKey: key).flatMap { ExploreDayKey.date(for: $0, timeZone: calendar.timeZone) }
    }

    /// The Journal opens on "Yesterday", the day people look back on. Its key is this morning's.
    static func yesterdayStorageKey(today: String = Repository.localDayKey(Date())) -> String { today }

    /// "Today" is logged under tomorrow morning's key.
    static func todayStorageKey(today: String = Repository.localDayKey(Date())) -> String {
        shifted(today, by: 1) ?? today
    }

    /// Any past day, and today. Nothing after today can have happened yet.
    static func isSelectable(_ key: String, today: String = Repository.localDayKey(Date())) -> Bool {
        guard let number = ExploreDayKey.dayNumber(for: key),
              let latest = ExploreDayKey.dayNumber(for: today) else { return false }
        return number <= latest + 1
    }

    // MARK: Words

    /// "Today", "Yesterday" or "Wed, Oct 21" for the behaviour day a key describes.
    static func label(forStorageKey key: String, today: String = Repository.localDayKey(Date())) -> String {
        guard let behavior = behaviorKey(forStorageKey: key) else { return String(localized: "this day") }
        return FriendlyDayLabel.label(forDayKey: behavior, today: today)
    }

    /// "Oct 21": the behaviour day without its weekday, for a caption or a done line.
    static func shortDate(forStorageKey key: String) -> String {
        guard let behavior = behaviorKey(forStorageKey: key), let date = ExploreDayKey.date(for: behavior) else {
            return String(localized: "this day")
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Every sentence the Journal says about the selected day, so no screen words a day on its own.
    struct Words: Equatable {
        /// "Yesterday", "Today" or "Wed, Oct 21".
        let label: String
        /// "How was yesterday?"
        let moodTitle: String
        /// "Say how yesterday went"
        let dictationTitle: String
        /// "Yesterday’s logged"
        let doneTitle: String
        /// "Same as yesterday" on Today, "Same as the day before" anywhere else.
        let repeatTitle: String
        let isToday: Bool
        let isYesterday: Bool
    }

    static func words(forStorageKey key: String, today: String = Repository.localDayKey(Date())) -> Words {
        let label = label(forStorageKey: key, today: today)
        let isToday = key == todayStorageKey(today: today)
        let isYesterday = key == yesterdayStorageKey(today: today)
        let repeatTitle = isToday ? String(localized: "Same as yesterday") : String(localized: "Same as the day before")
        if isToday {
            return Words(label: label, moodTitle: String(localized: "How’s today going?"),
                         dictationTitle: String(localized: "Say how today’s going"),
                         doneTitle: String(localized: "Today’s logged"),
                         repeatTitle: repeatTitle, isToday: true, isYesterday: false)
        }
        if isYesterday {
            return Words(label: label, moodTitle: String(localized: "How was yesterday?"),
                         dictationTitle: String(localized: "Say how yesterday went"),
                         doneTitle: String(localized: "Yesterday’s logged"),
                         repeatTitle: repeatTitle, isToday: false, isYesterday: true)
        }
        return Words(label: label, moodTitle: String(localized: "How was \(label)?"),
                     dictationTitle: String(localized: "Say how \(label) went"),
                     doneTitle: String(localized: "\(shortDate(forStorageKey: key)) logged"),
                     repeatTitle: repeatTitle, isToday: false, isYesterday: false)
    }

    // MARK: The last two weeks

    /// The storage keys of the last `days` behaviour days, oldest first, ending on Yesterday, or on Today when
    /// `includesToday` (it is only shown once there is something on it to show, or it is the open day).
    static func window(today: String = Repository.localDayKey(Date()), includesToday: Bool,
                       days: Int = 14) -> [String] {
        guard days > 0 else { return [] }
        let last = includesToday ? todayStorageKey(today: today) : yesterdayStorageKey(today: today)
        return (0..<days).reversed().compactMap { shifted(last, by: -$0) }
    }

    /// Days in a row with something logged, counting back from `end` (inclusive).
    static func streak(logged: Set<String>, endingAt end: String) -> Int {
        var cursor = end
        var count = 0
        while logged.contains(cursor) {
            count += 1
            guard let earlier = shifted(cursor, by: -1) else { break }
            cursor = earlier
        }
        return count
    }

    /// Days in a row with something logged, counting back from Yesterday, plus Today when it has been logged.
    /// A Today that has not been started yet never breaks a streak that Yesterday kept.
    static func currentStreak(logged: Set<String>, today: String = Repository.localDayKey(Date())) -> Int {
        let todayKey = todayStorageKey(today: today)
        return streak(logged: logged, endingAt: logged.contains(todayKey) ? todayKey : yesterdayStorageKey(today: today))
    }
}
