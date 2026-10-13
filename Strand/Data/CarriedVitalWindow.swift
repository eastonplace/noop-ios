import Foundation
import NoopPhase34Core

/// How far back a prior night's vital may stand in for the current day on a surface that cannot label it.
///
/// Today stamps a carried vital "Last night · <date>" and, once the carried night is older than
/// `TodayView.carryFreshnessDays`, relabels it "Latest sleep". A Home Screen widget has no room for that
/// label, so it takes the same window as a hard limit: the day's own value, else the freshest earlier one
/// inside the window, else nothing. A weeks-old night is never shown as today's.
enum CarriedVitalWindow {
    /// Mirrors `TodayView.carryFreshnessDays`; a test pins the two together.
    static let maximumAgeDays = 2

    /// Whole days from `day` to `anchorDay`, or nil when either key is not a real civil day.
    static func ageDays(of day: String, relativeTo anchorDay: String) -> Int? {
        guard let prior = try? CivilDay(key: day), let anchor = try? CivilDay(key: anchorDay) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let from = try? prior.date(in: calendar), let to = try? anchor.date(in: calendar) else { return nil }
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    /// The earliest day a night can be carried from to `anchorDay`, for a read that has to cover the window.
    static func earliestDay(anchorDay: CivilDay) throws -> CivilDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = try anchorDay.date(in: calendar)
        guard let first = calendar.date(byAdding: .day, value: -maximumAgeDays, to: anchor) else {
            throw CivilDayError.unrepresentableDate
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: first)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw CivilDayError.unrepresentableDate
        }
        return try CivilDay(year: year, month: month, day: day)
    }

    /// True for the anchor day itself and for an earlier day no more than `maximumAgeDays` before it.
    static func permits(day: String, anchorDay: String) -> Bool {
        guard let age = ageDays(of: day, relativeTo: anchorDay) else { return false }
        return (0...maximumAgeDays).contains(age)
    }
}
