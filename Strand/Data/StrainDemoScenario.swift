#if DEBUG
import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// MARK: - DEBUG-only Strain demo scenarios
//
// `--demo-strain <name>` (with `--demo-seed`, simulator only) reshapes TODAY of the synthetic demo account so the
// Strain detail screen can be walked through every state without a strap:
//
//   workouts  three workouts today, one scored by NOOP, one carrying WHOOP's own number, one unscored; a cardio-led day
//   over      the same day on a low-recovery morning, so the strain sits above the target band
//   steps     no workouts, a quiet pulse and a long walk's worth of steps: the step floor sets the score
//   none      no workouts and a light day
//   building  a brand-new account: one day of data
//   early     heart-rate readings that have not yet opened the score's gate (fewer than 20)
//
// Each scenario has its own database file (see `AppleDemoSeeder.databaseFilename`, which also carries today's date, so
// a seed is always relative to the day it runs). Everything here is synthetic and deterministic, sits behind
// `AppleDemoSeeder.requested` (simulator-only) and is stripped from Release builds.
enum StrainDemoScenario: String, CaseIterable {
    case workouts, over, steps, none, building, early

    /// The scenario named on the command line, when the demo seed is also requested.
    static let requested: StrainDemoScenario? = {
        let arguments = CommandLine.arguments
        guard arguments.contains("--demo-seed"),
              let index = arguments.firstIndex(of: "--demo-strain"), arguments.indices.contains(index + 1)
        else { return nil }
        return StrainDemoScenario(rawValue: arguments[index + 1].lowercased())
    }()

    /// How many days of history the account has.
    var seededDays: Int { self == .building ? 1 : 120 }

    /// Today's step total (Apple Health daily row).
    var todaySteps: Int {
        switch self {
        case .steps: return 16_500
        case .none, .early: return 3_400
        default: return 8_200
        }
    }

    /// Today's recovery, which sets the strain target band. nil keeps the seed's own value.
    var todayRecovery: Double? {
        switch self {
        case .workouts, .steps, .building, .early: return 72
        case .over: return 28
        case .none: return 35
        }
    }

    // MARK: Workouts

    /// The workouts of today, placed relative to `now` so the scenario holds at any time of day. A workout that
    /// would start before 00:30 is dropped (an early-morning launch simply has fewer).
    struct DemoWorkout {
        let sport: String
        let source: String
        let deviceId: String
        let startOffset: Int        // seconds before now
        let minutes: Double
        let steadyBPM: Double
        /// 2 = NOOP's own score, nil strain version with a value = WHOOP's, nil value = unscored.
        let scored: Scored
        enum Scored { case noop, whoop(Double), none }
    }

    var todayWorkouts: [DemoWorkout] {
        switch self {
        case .workouts, .over, .building:
            return [
                DemoWorkout(sport: "Running", source: "manual", deviceId: AppleDemoSeeder.whoop,
                            startOffset: 6 * 3600 + 20 * 60, minutes: 52, steadyBPM: 156, scored: .noop),
                DemoWorkout(sport: "Strength", source: "whoop", deviceId: AppleDemoSeeder.whoop,
                            startOffset: 4 * 3600 + 20 * 60, minutes: 48, steadyBPM: 126, scored: .whoop(37.5)),
                DemoWorkout(sport: "Walking", source: "apple-health", deviceId: AppleDemoSeeder.apple,
                            startOffset: 95 * 60, minutes: 25, steadyBPM: 106, scored: .none),
            ]
        default:
            return []
        }
    }

    // MARK: Shaping the seed

    /// Rewrites today's rows (and boosts the heart rate inside every workout of the last two weeks, so the days the
    /// engine scores from the minute-level fixture rise and fall instead of reading flat).
    func shape(daily: inout [DailyMetric], appleRows: inout [AppleDaily], workouts: inout [WorkoutRow],
               now: Date, calendar: Calendar) {
        let dayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)

        workouts.removeAll { $0.startTs >= dayStart }
        var todayCount = 0
        for demo in todayWorkouts {
            let start = nowTs - demo.startOffset
            guard start >= dayStart + 30 * 60 else { continue }
            let end = start + Int(demo.minutes * 60)
            guard end < nowTs - 5 * 60 else { continue }
            todayCount += 1
            let strain: Double?
            let version: Int?
            switch demo.scored {
            case .noop:
                // The score NOOP's own activity scorer gives this effort (kept in step with the heart rate laid down
                // for it in `todayHeartRate`, within a point).
                strain = StrainScorerV2.storedValue(fromDisplay: 9.8)
                version = 2
            case .whoop(let stored):
                strain = stored
                version = nil
            case .none:
                strain = nil
                version = nil
            }
            workouts.append(WorkoutRow(
                startTs: start, endTs: end, sport: demo.sport, source: demo.source,
                durationS: demo.minutes * 60, energyKcal: (demo.minutes * 9.5).rounded(),
                avgHr: Int(demo.steadyBPM) - 4, maxHr: Int(demo.steadyBPM) + 14, strain: strain,
                distanceM: demo.sport == "Strength" ? nil : demo.minutes * 160,
                zonesJSON: nil, notes: nil, strainVersion: version))
        }

        if let last = daily.indices.last {
            let row = daily[last]
            daily[last] = DailyMetric(
                day: row.day, totalSleepMin: row.totalSleepMin, efficiency: row.efficiency,
                deepMin: row.deepMin, remMin: row.remMin, lightMin: row.lightMin,
                disturbances: row.disturbances, restingHr: row.restingHr, avgHrv: row.avgHrv,
                recovery: todayRecovery ?? row.recovery, strain: row.strain, exerciseCount: todayCount,
                spo2Pct: row.spo2Pct, skinTempDevC: row.skinTempDevC, respRateBpm: row.respRateBpm,
                steps: todaySteps, activeKcalEst: row.activeKcalEst)
        }
        if let last = appleRows.indices.last {
            let row = appleRows[last]
            appleRows[last] = AppleDaily(
                day: row.day, steps: todaySteps,
                activeKcal: (Double(todaySteps) * 0.045 + Double(todayCount) * 220).rounded(),
                basalKcal: row.basalKcal, vo2max: row.vo2max, avgHr: row.avgHr, maxHr: row.maxHr,
                walkingHr: row.walkingHr, weightKg: row.weightKg)
        }
    }

    /// NOOP's own (version 2) Day Strain for every earlier day, stored the way the engine stores it, so the week and
    /// the trend have history to draw. Wednesdays are left out: a real account has days nobody wore the strap.
    func persistedStrainRows(daily: [DailyMetric], today: String) -> [DailyMetric] {
        daily.compactMap { row in
            guard row.day != today, let strain = row.strain,
                  let date = Self.dayFormatter.date(from: row.day),
                  Calendar.current.component(.weekday, from: date) != 4 else { return nil }
            return DailyMetric(
                day: row.day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: strain,
                exerciseCount: nil, strainVersion: 2)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Raises the minute-level fixture's heart rate inside each past workout to a believable session: a ramp, a
    /// steady stretch near the workout's own average, a short cool-down.
    func boostWorkouts(in hr: inout [HRSample], workouts: [WorkoutRow], todayStart: Int) {
        guard let first = hr.first?.ts else { return }
        for workout in workouts where workout.startTs < todayStart {
            let duration = Double(workout.endTs - workout.startTs)
            guard duration > 0 else { continue }
            let steady = Double(workout.avgHr ?? 140)
            var ts = workout.startTs - (workout.startTs - first) % 60
            while ts < workout.endTs {
                let index = (ts - first) / 60
                if hr.indices.contains(index), hr[index].ts == ts {
                    let progress = Double(ts - workout.startTs) / duration
                    let shape = min(1, max(0, progress / 0.12)) * min(1, max(0, (1 - progress) / 0.08 + 0.35))
                    let bpm = 84 + (steady - 84) * min(1, shape) + 4 * Foundation.sin(Double(ts) / 97)
                    hr[index] = HRSample(ts: ts, bpm: Int(bpm.rounded()))
                }
                ts += 60
            }
        }
    }

    /// Today after waking: a 1 Hz strap stream (the real cadence) with a gentle daily arc, the day's workouts laid
    /// in, and R-R intervals for the stress ribbon. `early` instead ends with a handful of readings, too few to open
    /// the score's gate.
    func todayHeartRate(wake: Int, now: Int, workouts: [WorkoutRow], rng: inout SplitMix64)
        -> (hr: [HRSample], rr: [RRInterval]) {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        if self == .early {
            // Fifteen readings a minute apart at a hard effort: enough coverage for the live score to count them,
            // too few readings (< 20) for the batch scorer to.
            for step in 0..<15 {
                let ts = now - (14 - step) * 60
                hr.append(HRSample(ts: ts, bpm: Int((152 + rng.nextDouble() * 6).rounded())))
            }
            return (hr, rr)
        }
        guard now > wake else { return ([], []) }
        hr.reserveCapacity(now - wake)
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
        let midnight = Int(dayStart.timeIntervalSince1970)
        var t = wake
        while t < now {
            let hour = Double(t - midnight) / 3600
            var bpm = 62 + 9 * Foundation.sin((hour - 7) / 17 * .pi)
            bpm += walkingBump(at: t)
            if let session = workouts.first(where: { $0.startTs <= t && t < $0.endTs }) {
                let progress = Double(t - session.startTs) / Double(max(session.endTs - session.startTs, 1))
                let steady = Double(session.avgHr ?? 130) + 4
                let ramp = min(1, progress / 0.1) * min(1, (1 - progress) / 0.06 + 0.3)
                bpm = bpm + (steady - bpm) * min(1, ramp)
            }
            bpm += (rng.nextDouble() - 0.5) * 6
            let value = Int(min(max(bpm, 48), 186).rounded())
            hr.append(HRSample(ts: t, bpm: value))
            if t % 2 == 0 {
                let ms = Int((60_000 / Double(value) + (rng.nextDouble() - 0.5) * 44).rounded())
                rr.append(RRInterval(ts: t, rrMs: min(max(ms, 320), 1300)))
            }
            t += 1
        }
        return (hr, rr)
    }

    /// A few short walks across the day: a lift of 15 to 30 bpm that never reaches a training zone.
    private func walkingBump(at ts: Int) -> Double {
        let minute = ts / 60
        let phase = minute % 97
        guard phase < 6 else { return 0 }
        return self == .steps ? 34 : 22
    }
}
#endif
