import Foundation
import WhoopProtocol

/// Review round 4 (5): the one rule for a civil day's calorie total, shared by every surface that shows it
/// (Trends, the Coupled view, the Today snapshot behind the widget payloads). Every value is TOTAL energy
/// (resting + active), like the strap's own estimate. Pure: callers pass the day's values explicitly.
public enum DailyCalories {

    /// A completed day's strap total is trusted from this much worn time (12 h).
    public static let completedDayStrapCoverageSeconds: Double = 12 * 3_600
    /// Today's strap total is trusted once the strap has been worn for half the day so far.
    public static let todayStrapCoverageFraction: Double = 0.5

    /// Where a day's calorie total came from.
    public enum Source: Sendable, Equatable {
        /// The strap's full-day heart-rate estimate (`DailyMetric.activeKcalEst`), whether or not it covered the day.
        case strap
        /// Apple Health's measured active + basal energy.
        case appleActivePlusBasal
        /// Apple Health's active energy plus the profile's resting energy.
        case appleActivePlusProfileResting
    }

    /// A day's calorie total and where it came from.
    public struct Resolution: Sendable, Equatable {
        public let kcal: Double
        public let source: Source
    }

    /// The day's calorie total, in order:
    /// 1. the strap total when the strap covered the day (12 h worn; today, half the elapsed day),
    /// 2. else Apple Health's active + basal energy when it has both,
    /// 3. else the strap total, if any,
    /// 4. else Apple's active energy plus the profile's resting energy for the seconds the day has run (all of
    ///    it for a completed day, so a 23 h or 25 h day gets 23 or 25 hours of it),
    /// 5. else nil.
    /// This is the only place the order lives: `total` is this rule's number alone, and a screen that needs to
    /// say where the number came from reads `source` from here instead of re-deciding it.
    /// - Parameters:
    ///   - strapKcal: the strap's full-day estimate (`DailyMetric.activeKcalEst`).
    ///   - strapWornSeconds: how long the strap recorded valid heart rate that day. Nil for a total stored
    ///     before coverage was, which counts as covered (the estimate it always was).
    ///   - bmrKcalPerDay: the profile's resting energy per 24 h (`bmrKcalPerDay(profile:)`).
    ///   - daySeconds: the civil day's length (23 h or 25 h across a DST change); nil counts as 24 h.
    ///   - elapsedSeconds: seconds since the day began, for today; nil for a completed day.
    ///   `dayTiming(day:timeZone:now:)` gives both.
    public static func resolve(strapKcal: Double?,
                               strapWornSeconds: Double?,
                               appleActiveKcal: Double?,
                               appleBasalKcal: Double?,
                               bmrKcalPerDay: Double?,
                               daySeconds: Double? = nil,
                               elapsedSeconds: Double? = nil) -> Resolution? {
        if let strapKcal {
            let covered: Bool
            if let worn = strapWornSeconds {
                covered = elapsedSeconds.map { worn >= todayStrapCoverageFraction * $0 }
                    ?? (worn >= completedDayStrapCoverageSeconds)
            } else {
                covered = true
            }
            if covered { return Resolution(kcal: strapKcal, source: .strap) }
        }
        if let active = appleActiveKcal, let basal = appleBasalKcal {
            return Resolution(kcal: active + basal, source: .appleActivePlusBasal)
        }
        if let strapKcal { return Resolution(kcal: strapKcal, source: .strap) }
        if let active = appleActiveKcal, let bmr = bmrKcalPerDay {
            // Review round 5 (3): resting energy accrues per real second, not as a share of the day.
            let length = daySeconds ?? 86_400
            let seconds = elapsedSeconds.map { min(max(0, $0), length) } ?? length
            return Resolution(kcal: active + bmr * seconds / 86_400, source: .appleActivePlusProfileResting)
        }
        return nil
    }

    /// `resolve(...)`'s number: the day's calorie total by the one rule, or nil.
    public static func total(strapKcal: Double?,
                             strapWornSeconds: Double?,
                             appleActiveKcal: Double?,
                             appleBasalKcal: Double?,
                             bmrKcalPerDay: Double?,
                             daySeconds: Double? = nil,
                             elapsedSeconds: Double? = nil) -> Double? {
        resolve(strapKcal: strapKcal, strapWornSeconds: strapWornSeconds, appleActiveKcal: appleActiveKcal,
                appleBasalKcal: appleBasalKcal, bmrKcalPerDay: bmrKcalPerDay, daySeconds: daySeconds,
                elapsedSeconds: elapsedSeconds)?.kcal
    }

    /// The profile's resting energy per 24 h, at the rate the strap's full-day estimate fills off-wrist time
    /// with (the same fallbacks for an unset weight, height or age).
    public static func bmrKcalPerDay(profile: UserProfile) -> Double {
        Calories.restingKcalPerS(Calories.resolveCoeffs(profile.sex),
                                 weightKg: profile.weightKg > 0 ? profile.weightKg : 70.0,
                                 heightCm: profile.heightCm > 0 ? profile.heightCm : 170.0,
                                 age: profile.age > 0 ? profile.age : 30.0) * 86_400
    }

    /// Seconds of valid heart rate in `samples`, counted by the minute: each minute with a plausible reading
    /// counts 60 s, so a 1 Hz strap and a sparser recorder measure worn time on the same scale.
    public static func wornSeconds(_ samples: [HRSample]) -> Int {
        var minutes = Set<Int>()
        for sample in samples where HRValidity.isPlausible(sample.bpm) {
            minutes.insert(Int((Double(sample.ts) / 60).rounded(.down)))
        }
        return minutes.count * 60
    }

    /// `day`'s length and, when `now` falls inside it, the seconds elapsed, in `timeZone`.
    public static func dayTiming(day: String, timeZone: TimeZone, now: Date) -> (daySeconds: Double,
                                                                                elapsedSeconds: Double?)? {
        dayTiming(day: day, calendar: gregorianCalendar(in: timeZone), now: now)
    }

    /// The same, with the Gregorian calendar built once by the caller. A series of days (the Calories card, the
    /// Calories page, Explore) otherwise built a `Calendar` and a time-zone copy per day, which was most of the cost
    /// of resolving a multi-year Apple Health history.
    public static func dayTiming(day: String, calendar: Calendar, now: Date) -> (daySeconds: Double,
                                                                                elapsedSeconds: Double?)? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let daySeconds = next.timeIntervalSince(start)
        let elapsed = now >= start && now < next ? now.timeIntervalSince(start) : nil
        return (daySeconds, elapsed)
    }

    /// A Gregorian calendar in `timeZone`: the calendar `dayTiming(day:timeZone:now:)` measures a civil day with.
    public static func gregorianCalendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
