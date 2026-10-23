import Foundation

// AutoFactors.swift — yes/no day factors NOOP can read from the wearable alone, so Insights work
// for someone who never opens the Journal.
//
// Pure, deterministic, DB-free. Every factor is keyed by the OUTCOME day it can affect: the wake
// day of the following sleep, the same convention the Journal stores its answers under (an answer
// about behaviour day D is stored under D+1, the morning it affects). Because both sources share
// that key, EffectRanker compares them with one fixed lag of 0 against the morning's outcome.
//
//  - earlyBedtime       sleep onset before the user's own median onset, rounded to the half hour.
//                       A personal threshold (not a fixed 11 pm) guarantees both sides have days,
//                       so a night owl who is never in bed by 11 still gets a usable comparison.
//  - consistentBedtime  onset within ±30 min of the median onset of the previous 14 days
//                       (at least 7 prior nights required).
//  - sevenHours         7 h or more of sleep that night.
//  - sleepDebt          the three nights BEFORE this one were, together, 2 h or more short of
//                       each exact night’s need (SleepDebt ledger, excluding repayment).
//                       Prior nights only, so it never restates this night's own sleep.
//  - lateWorkout        a workout ended within 3 h before sleep onset.
//  - highStrain         the previous day's strain was in the top third of the user's own days.
//  - highSteps          the previous day's steps were in the top third of the user's own days.
//
// A night or day with no data takes no part: it is in neither the yes nor the no set.

public enum AutoFactor: String, CaseIterable, Sendable {
    case earlyBedtime = "auto.early_bedtime"
    case consistentBedtime = "auto.consistent_bedtime"
    case sevenHours = "auto.seven_hours"
    case sleepDebt = "auto.sleep_debt"
    case lateWorkout = "auto.late_workout"
    case highStrain = "auto.high_strain"
    case highSteps = "auto.high_steps"

    /// Factors that are part of how an outcome is scored are not tested against it (sleep length
    /// against the sleep score would only rediscover the formula).
    public func isTested(againstOutcomeKey key: String) -> Bool {
        !(self == .sevenHours && key == "sleep_performance")
    }
}

/// One detected sleep, keyed by the local wake day the app stores the night's metrics under.
public struct AutoFactorNight: Equatable, Sendable {
    public let wakeDay: String
    public let onsetTs: Int
    public let endTs: Int
    public init(wakeDay: String, onsetTs: Int, endTs: Int) {
        self.wakeDay = wakeDay; self.onsetTs = onsetTs; self.endTs = endTs
    }
}

/// One day's totals. `totalSleepMin` belongs to the night that ENDED on `day` (wake-day row);
/// `strain` and `steps` belong to the calendar day itself.
public struct AutoFactorDay: Equatable, Sendable {
    public let day: String
    public let totalSleepMin: Double?
    public let strain: Double?
    public let steps: Double?
    public init(day: String, totalSleepMin: Double?, strain: Double?, steps: Double?) {
        self.day = day; self.totalSleepMin = totalSleepMin; self.strain = strain; self.steps = steps
    }
}

public struct AutoFactorWorkout: Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public init(startTs: Int, endTs: Int) { self.startTs = startTs; self.endTs = endTs }
}

/// The outcome days on which a factor held (`yes`) or was known not to hold (`no`).
public struct AutoFactorSplit: Equatable, Sendable {
    public let factor: AutoFactor
    public let yes: Set<String>
    public let no: Set<String>
    public init(factor: AutoFactor, yes: Set<String>, no: Set<String>) {
        self.factor = factor; self.yes = yes; self.no = no
    }
}

public struct AutoFactorResult: Equatable, Sendable {
    public let splits: [AutoFactor: AutoFactorSplit]
    /// The early-bedtime threshold as minutes after midnight of the behaviour day. Values of 1440
    /// or more are after midnight (1470 = 12:30 am). Nil when there are too few nights.
    public let bedtimeThresholdMinutes: Int?
    public init(splits: [AutoFactor: AutoFactorSplit], bedtimeThresholdMinutes: Int?) {
        self.splits = splits; self.bedtimeThresholdMinutes = bedtimeThresholdMinutes
    }
}

public enum AutoFactors {

    public static let minNightsForBedtime = 7
    public static let consistencyWindowDays = 14
    public static let consistencyMinPriorNights = 7
    public static let consistencyToleranceMin = 30
    public static let sevenHoursMin: Double = 420
    public static let debtWindowNights = 3
    public static let debtThresholdMin: Double = 120
    public static let lateWorkoutWindowSec = 3 * 3600
    public static let minDaysForTopThird = 14
    /// Shorter sleeps are naps; the main sleep of a wake day is its longest at least this long.
    public static let mainSleepMinSec = 3 * 3600

    /// `sleepLedgerNeedsByDay` contains exact-night targets excluding debt repayment.
    /// Missing or invalid targets leave that three-night debt window unknown.
    public static func derive(nights: [AutoFactorNight],
                              days: [AutoFactorDay],
                              workouts: [AutoFactorWorkout],
                              calendar: Calendar,
                              sleepLedgerNeedsByDay: [String: Double] = [:]) -> AutoFactorResult {
        var splits: [AutoFactor: AutoFactorSplit] = [:]
        let main = mainNights(nights)
        let onsets = main.map { (night: $0, minutes: onsetClockMinutes($0.onsetTs, calendar: calendar)) }

        // Early bedtime against the personal median.
        var threshold: Int?
        if onsets.count >= minNightsForBedtime {
            let t = roundedToHalfHour(ComparisonEngine.median(onsets.map { Double($0.minutes) }))
            threshold = t
            var yes = Set<String>(), no = Set<String>()
            for o in onsets { if o.minutes < t { yes.insert(o.night.wakeDay) } else { no.insert(o.night.wakeDay) } }
            splits[.earlyBedtime] = AutoFactorSplit(factor: .earlyBedtime, yes: yes, no: no)
        }

        // Consistency against the trailing 14-day median.
        do {
            var yes = Set<String>(), no = Set<String>()
            for o in onsets {
                guard let from = CorrelationEngine.shiftDay(o.night.wakeDay, by: -consistencyWindowDays) else { continue }
                let prior = onsets.filter { $0.night.wakeDay >= from && $0.night.wakeDay < o.night.wakeDay }
                guard prior.count >= consistencyMinPriorNights else { continue }
                let median = ComparisonEngine.median(prior.map { Double($0.minutes) })
                if abs(Double(o.minutes) - median) <= Double(consistencyToleranceMin) {
                    yes.insert(o.night.wakeDay)
                } else {
                    no.insert(o.night.wakeDay)
                }
            }
            if !yes.isEmpty || !no.isEmpty {
                splits[.consistentBedtime] = AutoFactorSplit(factor: .consistentBedtime, yes: yes, no: no)
            }
        }

        // Sleep length and debt, both on wake-day rows.
        let sleepByDay: [String: Double] = Dictionary(
            days.compactMap { d in d.totalSleepMin.flatMap { $0 > 0 && $0.isFinite ? (d.day, $0) : nil } },
            uniquingKeysWith: { _, last in last })
        if !sleepByDay.isEmpty {
            var yes = Set<String>(), no = Set<String>()
            for (day, minutes) in sleepByDay {
                if minutes >= sevenHoursMin { yes.insert(day) } else { no.insert(day) }
            }
            splits[.sevenHours] = AutoFactorSplit(factor: .sevenHours, yes: yes, no: no)

            var debtYes = Set<String>(), debtNo = Set<String>()
            let candidates = Set(sleepByDay.keys.compactMap { CorrelationEngine.shiftDay($0, by: 1) })
                .union(sleepByDay.keys)
            for wake in candidates {
                let priorKeys = (1...debtWindowNights).reversed().compactMap { CorrelationEngine.shiftDay(wake, by: -$0) }
                let prior = priorKeys.map { (day: $0, totalSleepMin: sleepByDay[$0], needMin: sleepLedgerNeedsByDay[$0]) }
                let ledger = SleepDebt.ledger(nightlyNeeds: prior, window: debtWindowNights)
                guard ledger.nightCount == debtWindowNights, ledger.balanceMin.isFinite else { continue }
                if ledger.balanceMin <= -debtThresholdMin { debtYes.insert(wake) } else { debtNo.insert(wake) }
            }
            if !debtYes.isEmpty || !debtNo.isEmpty {
                splits[.sleepDebt] = AutoFactorSplit(factor: .sleepDebt, yes: debtYes, no: debtNo)
            }
        }

        // Late workouts: one that ended within the window before onset.
        if !main.isEmpty {
            var yes = Set<String>(), no = Set<String>()
            for night in main {
                let late = workouts.contains { w in
                    w.endTs <= night.onsetTs && w.endTs >= night.onsetTs - lateWorkoutWindowSec
                }
                if late { yes.insert(night.wakeDay) } else { no.insert(night.wakeDay) }
            }
            splits[.lateWorkout] = AutoFactorSplit(factor: .lateWorkout, yes: yes, no: no)
        }

        // Top-third days, attributed to the next morning.
        if let s = topThirdSplit(.highStrain, days.compactMap { d in d.strain.map { (d.day, $0) } }) {
            splits[.highStrain] = s
        }
        if let s = topThirdSplit(.highSteps, days.compactMap { d in d.steps.map { (d.day, $0) } }) {
            splits[.highSteps] = s
        }

        return AutoFactorResult(splits: splits, bedtimeThresholdMinutes: threshold)
    }

    // MARK: - Helpers

    /// The longest sleep of each wake day, when it is long enough to be the main sleep.
    static func mainNights(_ nights: [AutoFactorNight]) -> [AutoFactorNight] {
        var best: [String: AutoFactorNight] = [:]
        for n in nights where n.endTs - n.onsetTs >= mainSleepMinSec {
            if let cur = best[n.wakeDay], cur.endTs - cur.onsetTs >= n.endTs - n.onsetTs { continue }
            best[n.wakeDay] = n
        }
        return best.values.sorted { $0.wakeDay < $1.wakeDay }
    }

    /// Local clock minutes of an onset, counted from midnight of the evening it belongs to, so
    /// 11 pm is 1380 and 12:30 am is 1470. Onsets before noon are treated as after midnight.
    public static func onsetClockMinutes(_ ts: Int, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minutes < 12 * 60 ? minutes + 24 * 60 : minutes
    }

    static func roundedToHalfHour(_ minutes: Double) -> Int {
        Int((minutes / 30).rounded()) * 30
    }

    /// Days at or above the top-third cut are `yes`; the rest are `no`. Keys move to the next
    /// morning. Nil until there are enough days for the cut to mean anything.
    static func topThirdSplit(_ factor: AutoFactor, _ values: [(String, Double)]) -> AutoFactorSplit? {
        let usable = values.filter { $0.1.isFinite && $0.1 > 0 }
        guard usable.count >= minDaysForTopThird, let cut = topThirdThreshold(usable.map(\.1)) else { return nil }
        var yes = Set<String>(), no = Set<String>()
        for (day, value) in usable {
            guard let morning = CorrelationEngine.shiftDay(day, by: 1) else { continue }
            if value >= cut { yes.insert(morning) } else { no.insert(morning) }
        }
        return AutoFactorSplit(factor: factor, yes: yes, no: no)
    }

    /// The smallest value in the top third of `values` (the top ⌊n/3⌋ by rank).
    static func topThirdThreshold(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        let topCount = sorted.count / 3
        guard topCount > 0 else { return nil }
        return sorted[sorted.count - topCount]
    }
}
