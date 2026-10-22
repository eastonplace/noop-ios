import Foundation

/// An explainable planning heuristic. All Strain inputs and outputs use NOOP's stored 0...100 axis.
/// These are daily totals: nonlinear workout Strain must never be added to, or subtracted from, them.
/// This model changes no recorded metric and does not estimate exercise duration or medical readiness.
public enum DailyTrainingTargetEngine {
    public static let modelVersion = "daily-training-target-v1"
    public static let historyDays = 56
    public static let recentDays = 14
    public static let minimumObservedDays = 7

    public struct Day: Equatable, Sendable {
        public let day: String
        public let strainStored: Double?
        public let recovery: Double?

        public init(day: String, strainStored: Double?, recovery: Double?) {
            self.day = day; self.strainStored = strainStored; self.recovery = recovery
        }
    }

    public struct Input: Equatable, Sendable {
        public let day: String
        public let recovery: Double?
        public let sleptHours: Double?
        public let sleepNeedHours: Double?
        public let sleepNeedDay: String?
        public let sleepNeedObservationCount: Int
        /// Nil means current progress is unknown or stale. It must not become a measured zero.
        public let currentStrainStored: Double?
        public let history: [Day]

        public init(day: String, recovery: Double?, sleptHours: Double?, sleepNeedHours: Double?,
                    sleepNeedDay: String?, currentStrainStored: Double?, history: [Day],
                    sleepNeedObservationCount: Int = 1) {
            self.day = day; self.recovery = recovery; self.sleptHours = sleptHours
            self.sleepNeedHours = sleepNeedHours; self.sleepNeedDay = sleepNeedDay
            self.currentStrainStored = currentStrainStored; self.history = history
            self.sleepNeedObservationCount = sleepNeedObservationCount
        }
    }

    public enum UnavailableReason: Equatable, Sendable {
        case invalidDay, needsRecovery, needsSleep, needsSleepNeed, needsRecentHistory, invalidHistory
    }
    public enum Driver: Equatable, Sendable {
        case recoveryLow, recoveryModerate, recoveryHigh, sleepShort, sleepMet, recentLoadHigh, loadBuilding
    }
    public enum Progress: Equatable, Sendable { case unknown, below, within, above }

    public struct Target: Equatable, Sendable {
        public let lowerStored: Double
        public let upperStored: Double
        public let usualStrainStored: Double
        public let observedDays: Int
        public let recovery: Double
        public let sleepRatio: Double
        public let drivers: [Driver]
        public let progress: Progress
    }

    public struct Result: Equatable, Sendable {
        public let day: String
        public let target: Target?
        public let unavailableReason: UnavailableReason?
        public let observedDays: Int
        public let load: TrainingLoadEngine.Result?
        public let currentStrainStored: Double?
        public let sleepNeedHours: Double?
        public let sleepNeedDay: String?
        fileprivate let recentRecovery: [Double]
        fileprivate let recentEffort: [Double]
        fileprivate let needNights: Int
    }

    public struct Preview: Equatable, Sendable {
        public let plannedTotalStored: Double
        public let plannedSleepHours: Double
        public let acuteLoad: Double?
        public let chronicLoad: Double?
        public let recovery: RecoveryForecast?

        public var loadRatio: Double? {
            guard let acuteLoad, let chronicLoad, chronicLoad > 0.1 else { return nil }
            return acuteLoad / chronicLoad
        }
    }

    public static func evaluate(_ input: Input) -> Result {
        func unavailable(_ reason: UnavailableReason, observed: Int = 0) -> Result {
            Result(day: input.day, target: nil, unavailableReason: reason, observedDays: observed,
                   load: nil, currentStrainStored: nil, sleepNeedHours: nil, sleepNeedDay: nil,
                   recentRecovery: [], recentEffort: [], needNights: 0)
        }
        guard let yesterday = offsetDay(input.day, by: -1),
              let start = offsetDay(input.day, by: -historyDays),
              let recentStart = offsetDay(input.day, by: -recentDays),
              let needStart = offsetDay(input.day, by: -6) else { return unavailable(.invalidDay) }
        guard let recovery = valid(input.recovery, in: 0...100) else { return unavailable(.needsRecovery) }
        guard let slept = valid(input.sleptHours, in: 0...24) else { return unavailable(.needsSleep) }
        guard let need = valid(input.sleepNeedHours, in: 1...24),
              let needDay = input.sleepNeedDay, offsetDay(needDay, by: 0) != nil,
              needDay >= needStart, needDay <= input.day else { return unavailable(.needsSleepNeed) }

        var seen = Set<String>()
        var history: [Day] = []
        for row in input.history {
            guard offsetDay(row.day, by: 0) != nil else { return unavailable(.invalidHistory) }
            // Neither today's partial total nor a future row can seed yesterday's load or usual day.
            guard row.day >= start, row.day < input.day else { continue }
            guard seen.insert(row.day).inserted else { return unavailable(.invalidHistory) }
            if let load = row.strainStored, valid(load, in: 0...100) == nil {
                return unavailable(.invalidHistory)
            }
            history.append(row)
        }
        history.sort { $0.day < $1.day }
        let recent = history.filter { $0.day >= recentStart }
        let observed = recent.compactMap(\.strainStored)
        guard observed.count >= minimumObservedDays,
              recent.last?.day == yesterday, recent.last?.strainStored != nil else {
            return unavailable(.needsRecentHistory, observed: observed.count)
        }
        let sorted = observed.sorted()
        let middle = sorted.count / 2
        let usual = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let load = TrainingLoadEngine.evaluate(
            days: history.map { .init(day: $0.day, load: $0.strainStored) }, through: yesterday)

        var drivers: [Driver] = []
        let recoveryFactor: Double
        // Match the rounded Recovery score and bands shown by the existing dashboard.
        let displayedRecovery = recovery.rounded()
        if displayedRecovery < 34 { recoveryFactor = 0.60; drivers.append(.recoveryLow) }
        else if displayedRecovery < 67 { recoveryFactor = 0.85; drivers.append(.recoveryModerate) }
        else { recoveryFactor = 1.05; drivers.append(.recoveryHigh) }
        let sleepRatio = slept / need
        let sleepFactor = 0.7 + 0.3 * min(1, sleepRatio)
        drivers.append(sleepRatio < 0.9 ? .sleepShort : .sleepMet)
        var loadFactor = 1.0
        if load.isAvailable, let acute = load.acuteLoad, let chronic = load.chronicLoad, chronic > 0.1 {
            let ratio = acute / chronic
            if ratio > 1.2 {
                loadFactor = max(0.7, 1.2 / ratio)
                drivers.append(.recentLoadHigh)
            }
        } else { drivers.append(.loadBuilding) }

        // Explicit policy constants, not a fitted physiological model. UI discloses these factors.
        let adjusted = usual * recoveryFactor * sleepFactor * loadFactor
        let lower = min(100, max(0, adjusted * 0.85))
        let upper = min(100, max(lower, adjusted * 1.10))
        let current = valid(input.currentStrainStored, in: 0...100)
        let progress: Progress
        if let current {
            progress = current < lower ? .below : (current > upper ? .above : .within)
        } else { progress = .unknown }
        let target = Target(lowerStored: lower, upperStored: upper, usualStrainStored: usual,
                            observedDays: observed.count, recovery: recovery, sleepRatio: sleepRatio,
                            drivers: drivers, progress: progress)
        return Result(day: input.day, target: target, unavailableReason: nil, observedDays: observed.count,
                      load: load, currentStrainStored: current, sleepNeedHours: need, sleepNeedDay: needDay,
                      recentRecovery: Array((recent.compactMap { valid($0.recovery, in: 0...100) } + [recovery]).suffix(14)),
                      recentEffort: observed, needNights: min(14, max(0, input.sleepNeedObservationCount)))
    }

    /// Preview the end of the current day and next morning. Existing model math remains authoritative.
    public static func preview(_ result: Result, plannedTotalStored: Double,
                               plannedSleepHours: Double) -> Preview? {
        guard result.target != nil, let current = result.currentStrainStored,
              valid(plannedTotalStored, in: current...100) != nil,
              valid(plannedSleepHours, in: 1...24) != nil, let need = result.sleepNeedHours else { return nil }
        var acute: Double?
        var chronic: Double?
        if let load = result.load, load.isAvailable,
           let beforeAcute = load.acuteLoad, let beforeChronic = load.chronicLoad {
            let stepped = TrainingLoadEngine.step(acute: beforeAcute, chronic: beforeChronic, load: plannedTotalStored)
            acute = stepped.acute; chronic = stepped.chronic
        }
        let forecast = RecoveryForecaster.forecast(
            recentCharge: result.recentRecovery, recentEffort: result.recentEffort,
            todayEffort: plannedTotalStored, plannedSleepHours: plannedSleepHours,
            needHours: need, needNights: result.needNights)
        return Preview(plannedTotalStored: plannedTotalStored, plannedSleepHours: plannedSleepHours,
                       acuteLoad: acute, chronicLoad: chronic, recovery: forecast)
    }

    private static func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// Strict civil-day arithmetic in UTC. The adapter supplies the user's logical-day key.
    /// A fixed civil calendar avoids a DST day becoming 23/24 of an observation.
    public static func offsetDay(_ key: String, by offset: Int) -> String? {
        guard key.utf8.count == 10 else { return nil }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              let shifted = calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
        let value = calendar.dateComponents([.year, .month, .day], from: shifted)
        guard let y = value.year, let m = value.month, let d = value.day, (1...9999).contains(y) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
