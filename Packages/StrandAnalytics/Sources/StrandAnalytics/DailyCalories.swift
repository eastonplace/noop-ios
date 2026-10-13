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

    /// The day's calorie total, in order:
    /// 1. the strap total when the strap covered the day (12 h worn; today, half the elapsed day),
    /// 2. else Apple Health's active + basal energy when it has both,
    /// 3. else the strap total, if any,
    /// 4. else Apple's active energy plus the profile's resting energy for the day (prorated today),
    /// 5. else nil.
    /// - Parameters:
    ///   - strapKcal: the strap's full-day estimate (`DailyMetric.activeKcalEst`).
    ///   - strapWornSeconds: how long the strap recorded valid heart rate that day. Nil for a total stored
    ///     before coverage was, which counts as covered (the estimate it always was).
    ///   - bmrKcalPerDay: the profile's resting energy per 24 h (`bmrKcalPerDay(profile:)`).
    ///   - daySeconds: the civil day's length (23 h or 25 h across a DST change), used to prorate today.
    ///   - elapsedSeconds: seconds since the day began, for today; nil for a completed day.
    ///   `dayTiming(day:timeZone:now:)` gives both.
    public static func total(strapKcal: Double?,
                             strapWornSeconds: Double?,
                             appleActiveKcal: Double?,
                             appleBasalKcal: Double?,
                             bmrKcalPerDay: Double?,
                             daySeconds: Double? = nil,
                             elapsedSeconds: Double? = nil) -> Double? {
        if let strapKcal {
            let covered: Bool
            if let worn = strapWornSeconds {
                covered = elapsedSeconds.map { worn >= todayStrapCoverageFraction * $0 }
                    ?? (worn >= completedDayStrapCoverageSeconds)
            } else {
                covered = true
            }
            if covered { return strapKcal }
        }
        if let active = appleActiveKcal, let basal = appleBasalKcal { return active + basal }
        if let strapKcal { return strapKcal }
        if let active = appleActiveKcal, let bmr = bmrKcalPerDay {
            var share = 1.0
            if let elapsed = elapsedSeconds, let length = daySeconds, length > 0 {
                share = min(1, max(0, elapsed / length))
            }
            return active + bmr * share
        }
        return nil
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let daySeconds = next.timeIntervalSince(start)
        let elapsed = now >= start && now < next ? now.timeIntervalSince(start) : nil
        return (daySeconds, elapsed)
    }
}
