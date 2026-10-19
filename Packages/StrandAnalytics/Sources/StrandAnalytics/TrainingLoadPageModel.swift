import Foundation
import WhoopStore

/// Every derived number on the Training load page, so the view only draws.
///
/// It reads the modeled days `TrainingLoadEngine` already produced plus the workouts of the last few weeks, and answers
/// the page's questions in plain values: the recent-load to fitness-base ratio and its band, what changed since a week
/// ago, where tomorrow could land, the last six calendar weeks, what drove a week, where the load came from and how the
/// last four weeks compare with the four before. Nothing here re-models load: the "tomorrow" rows call the engine's own
/// `TrainingLoadEngine.step`, and everything else is arithmetic on its points.
///
/// Scale. The engine's acute and chronic values are in the units of the daily load it was given: NOOP stores daily
/// strain on 0...100, so they come out on 0...100. People read Effort on 0...21, so every figure this model returns for
/// display is `stored * displayFactor` (0.21). The ratio is unitless and the same on both scales. `Day` carries stored
/// values; `Projection`, `Week`, `Driver` and the rest carry display values.
///
/// Descriptive only. Nothing here reads or changes Readiness.
public struct TrainingLoadPageModel: Sendable {

    // MARK: - Inputs

    /// One observed, modeled day, in the engine's stored units. `date` is the start of that calendar day in the model's
    /// calendar.
    public struct Day: Sendable, Equatable {
        public let date: Date
        public let acute: Double
        public let chronic: Double
        public let load: Double

        public init(date: Date, acute: Double, chronic: Double, load: Double) {
            self.date = date
            self.acute = acute
            self.chronic = chronic
            self.load = load
        }
    }

    /// One workout. `strain` is NOOP's own stored 0...100 score for it, nil when NOOP did not score it (an Apple Health or
    /// imported session): such a workout still makes its day a training day but is not ranked or counted into the mix.
    public struct Workout: Sendable, Equatable {
        public let start: Date
        public let sport: String
        public let strain: Double?
        public let durationSeconds: Double?
        public let energyKcal: Double?
        public let distanceMeters: Double?

        public init(start: Date, sport: String, strain: Double?, durationSeconds: Double? = nil,
                    energyKcal: Double? = nil, distanceMeters: Double? = nil) {
            self.start = start
            self.sport = sport
            self.strain = strain
            self.durationSeconds = durationSeconds
            self.energyKcal = energyKcal
            self.distanceMeters = distanceMeters
        }

        /// A stored workout row. The strain is the canonical NOOP V2 value only (`StrainResolver.canonicalWorkout`), the
        /// same chain the daily Effort that feeds the model comes from, never an imported or legacy number.
        public init(row: WorkoutRow, sportName: String) {
            let span = Double(row.endTs - row.startTs)
            let seconds: Double? = {
                if let recorded = row.durationS, recorded > 0 { return recorded }
                return span > 0 ? span : nil
            }()
            let strain = StrainResolver.canonicalWorkout(row)?.storedValue
            self.init(start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                      sport: sportName,
                      strain: strain.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                      durationSeconds: seconds,
                      energyKcal: row.energyKcal.flatMap { $0 > 0 ? $0 : nil },
                      distanceMeters: row.distanceM.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    // MARK: - Bands and zones

    /// The page's headline, from the ratio of recent load to fitness base.
    public enum Headline: Sendable, Equatable {
        /// Under 0.8.
        case easing
        /// 0.8 up to 1.0.
        case holding
        /// 1.0 up to 1.3.
        case building
        /// 1.3 and above.
        case spiking
    }

    /// The zone a ratio sits in on the gauge and on the "tomorrow" rows.
    public enum Zone: Sendable, Equatable {
        /// Under 0.8.
        case easing
        /// 0.8 up to 1.25.
        case sweetSpot
        /// 1.25 up to 1.3.
        case nearSpike
        /// 1.3 and above.
        case spike
    }

    /// Where the gauge starts and ends. A ratio outside it pins the marker to the nearer end.
    public static let gaugeRange: ClosedRange<Double> = 0.5...1.6
    public static let easingBelow = 0.8
    public static let sweetSpotThrough = 1.3
    public static let holdingFrom = 0.8
    public static let buildingFrom = 1.0
    public static let nearSpikeFrom = 1.25
    public static let spikeFrom = 1.3

    /// A fitness base this close to nothing has no meaningful ratio (stored units).
    public static let minimumBase = 0.1

    /// Recent load over fitness base, or nil when the base is too small to divide by.
    public static func ratio(acute: Double, chronic: Double) -> Double? {
        guard acute.isFinite, chronic.isFinite, chronic > minimumBase else { return nil }
        return acute / chronic
    }

    /// The ratio as the page prints it (two decimals). Bands read this, so "1.30×" is never drawn under a sweet-spot
    /// headline.
    public static func displayedRatio(_ ratio: Double) -> Double {
        (ratio * 100).rounded() / 100
    }

    public static func headline(forRatio ratio: Double) -> Headline {
        let value = displayedRatio(ratio)
        if value < holdingFrom { return .easing }
        if value < buildingFrom { return .holding }
        if value < spikeFrom { return .building }
        return .spiking
    }

    public static func zone(forRatio ratio: Double) -> Zone {
        let value = displayedRatio(ratio)
        if value < easingBelow { return .easing }
        if value < nearSpikeFrom { return .sweetSpot }
        if value < spikeFrom { return .nearSpike }
        return .spike
    }

    /// 0...1 along the gauge, clamped.
    public static func gaugeFraction(forRatio ratio: Double) -> Double {
        let span = gaugeRange.upperBound - gaugeRange.lowerBound
        return min(max((ratio - gaugeRange.lowerBound) / span, 0), 1)
    }

    /// How far recent load sits from the base, as the whole percent the lede names (positive above the base).
    public static func percentFromBase(ratio: Double) -> Int {
        Int(((ratio - 1) * 100).rounded())
    }

    // MARK: - Outputs

    /// Display scale: stored * this.
    public let displayFactor: Double
    public let calendar: Calendar
    public let configuration: TrainingLoadEngine.Configuration
    /// Every observed modeled day, oldest first.
    public let days: [Day]
    public let workouts: [Workout]

    /// The newest modeled day: the page's "today".
    public var latest: Day? { days.last }

    /// Recent load over fitness base on the newest day.
    public let ratio: Double?
    public let headline: Headline?
    /// The newest day's figures on the 0...21 display scale.
    public let recent: Double?
    public let base: Double?
    /// Fitness base minus recent load. Below zero the person is training above their base.
    public let form: Double?
    /// How each moved since about a week ago; nil without a day close enough to a week back.
    public let recentChange: Change?
    public let baseChange: Change?
    public let projections: [Projection]
    /// The last six calendar weeks, oldest first, the newest holding the newest day.
    public let weeks: [Week]
    public let comparison: Comparison?

    /// A change in a display-scale value and how many calendar days back the comparison point is.
    public struct Change: Sendable, Equatable {
        public let delta: Double
        public let daysAgo: Int
        /// Exactly a week back, the usual case; fewer or more when a missing day moved the comparison point.
        public var isWeek: Bool { daysAgo == 7 }
    }

    public enum Scenario: Sendable, Equatable, CaseIterable {
        case rest, moderate, allOut

        /// The Effort (0...21) the page asks "what if" with.
        public var effort: Double {
            switch self {
            case .rest: 0
            case .moderate: 12
            case .allOut: 19
            }
        }
    }

    /// The engine's own next step for one imagined Effort.
    public struct Projection: Sendable, Equatable {
        public let scenario: Scenario
        public let effort: Double
        /// Recent load and fitness base after that day, display scale.
        public let recent: Double
        public let base: Double
        public let ratio: Double?
        public let zone: Zone?
    }

    public struct Week: Sendable, Equatable {
        /// First day of the calendar week (the calendar's first weekday).
        public let start: Date
        /// Mean daily Effort over the week's observed days, display scale; nil when none were observed.
        public let averageEffort: Double?
        /// Fitness base on the week's last observed day (the newest day for the current week), display scale.
        public let baseAtEnd: Double?
        public let isCurrent: Bool
        public let observedDays: Int
    }

    public struct Driver: Sendable, Equatable {
        public let workout: Workout
        /// The workout's strain on the 0...21 display scale.
        public let effort: Double
        /// `effort` as a share of the 21-point scale, for the bar under it.
        public let fraction: Double
    }

    /// The seven days ending on a day, the workouts that carried them and how many days held a workout.
    public struct DriverWeek: Sendable, Equatable {
        public let first: Date
        public let last: Date
        public let drivers: [Driver]
        public let trainingDays: Int
    }

    public struct SportShare: Sendable, Equatable {
        public let name: String
        /// The overflow bucket ("Other"), not a sport of its own.
        public let isOther: Bool
        public let fraction: Double
        /// Whole percent; the set sums to exactly 100.
        public let percent: Int
    }

    public struct Comparison: Sendable, Equatable {
        public struct Biggest: Sendable, Equatable {
            public let date: Date
            public let effort: Double
        }
        public let averageEffort: Double
        public let previousAverageEffort: Double
        public var averageDelta: Double { averageEffort - previousAverageEffort }
        /// Days with at least one workout in each window; nil when no workout was read at all.
        public let trainingDays: Int?
        public let previousTrainingDays: Int?
        public var trainingDaysDelta: Int? {
            guard let trainingDays, let previousTrainingDays else { return nil }
            return trainingDays - previousTrainingDays
        }
        public let biggestDay: Biggest
    }

    /// Fewest observed days the earlier window needs before the comparison is drawn.
    public static let minimumComparisonDays = 7
    public static let comparisonWindowDays = 28
    public static let weekCount = 6
    public static let mixWindowDays = 42
    public static let driverCount = 3
    public static let mixSportCount = 3

    // MARK: - Init

    /// - Parameters:
    ///   - days: observed modeled days in the engine's stored units, any order.
    ///   - workouts: the workouts read for the window, any order.
    ///   - calendar: the one calendar every day bucket and week uses; set its `firstWeekday` to the person's.
    public init(days: [Day], workouts: [Workout], calendar: Calendar,
                configuration: TrainingLoadEngine.Configuration = .standard,
                displayFactor: Double = 0.21) {
        let ordered = days.sorted { $0.date < $1.date }
        self.days = ordered
        self.workouts = workouts
        self.calendar = calendar
        self.configuration = configuration
        self.displayFactor = displayFactor

        let latest = ordered.last
        let ratio = latest.flatMap { Self.ratio(acute: $0.acute, chronic: $0.chronic) }
        self.ratio = ratio
        self.headline = ratio.map(Self.headline(forRatio:))
        self.recent = latest.map { $0.acute * displayFactor }
        self.base = latest.map { $0.chronic * displayFactor }
        self.form = latest.map { ($0.chronic - $0.acute) * displayFactor }
        self.recentChange = Self.makeChange(in: ordered, calendar: calendar, maxGap: configuration.maxGapDays,
                                        factor: displayFactor) { $0.acute }
        self.baseChange = Self.makeChange(in: ordered, calendar: calendar, maxGap: configuration.maxGapDays,
                                      factor: displayFactor) { $0.chronic }
        self.projections = latest.map {
            Self.makeProjections(from: $0, configuration: configuration, displayFactor: displayFactor)
        } ?? []
        self.weeks = latest.map {
            Self.makeWeeks(in: ordered, newest: $0.date, calendar: calendar, displayFactor: displayFactor)
        } ?? []
        self.comparison = latest.flatMap {
            Self.makeComparison(days: ordered, workouts: workouts, newest: $0.date, calendar: calendar,
                            displayFactor: displayFactor)
        }
    }

    // MARK: - Form

    /// What the sign of Form says. The tolerance is half of the 0.1 the page prints, so a Form that prints "0.0" is level.
    public enum FormState: Sendable, Equatable {
        /// Below zero: recent load is above the base.
        case aboveBase
        case level
        /// Above zero: recent load is below the base.
        case fresher
    }

    public var formState: FormState? {
        guard let form else { return nil }
        if abs(form) < 0.05 { return .level }
        return form < 0 ? .aboveBase : .fresher
    }

    // MARK: - Changes

    private static func makeChange(in days: [Day], calendar: Calendar, maxGap: Int, factor: Double,
                               _ value: (Day) -> Double) -> Change? {
        guard let latest = days.last,
              let target = calendar.date(byAdding: .day, value: -7, to: latest.date) else { return nil }
        // The day exactly a week back when it was observed, else the nearest observed day before it that a tolerated
        // gap could explain. Never a later day: a comparison point is always at least a week old.
        guard let reference = days.last(where: { $0.date <= target }),
              let gap = calendar.dateComponents([.day], from: reference.date, to: target).day,
              gap <= maxGap,
              let back = calendar.dateComponents([.day], from: reference.date, to: latest.date).day else { return nil }
        return Change(delta: (value(latest) - value(reference)) * factor, daysAgo: back)
    }

    // MARK: - Tomorrow

    private static func makeProjections(from latest: Day, configuration: TrainingLoadEngine.Configuration,
                                    displayFactor: Double) -> [Projection] {
        Scenario.allCases.map { scenario in
            let stored = scenario.effort / displayFactor
            let next = TrainingLoadEngine.step(acute: latest.acute, chronic: latest.chronic, load: stored,
                                               configuration: configuration)
            let ratio = Self.ratio(acute: next.acute, chronic: next.chronic)
            return Projection(scenario: scenario, effort: scenario.effort,
                              recent: next.acute * displayFactor, base: next.chronic * displayFactor,
                              ratio: ratio, zone: ratio.map(Self.zone(forRatio:)))
        }
    }

    // MARK: - Weeks

    private static func makeWeeks(in days: [Day], newest: Date, calendar: Calendar, displayFactor: Double) -> [Week] {
        guard let currentStart = calendar.dateInterval(of: .weekOfYear, for: newest)?.start else { return [] }
        var result: [Week] = []
        for offset in stride(from: weekCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -7 * offset, to: currentStart),
                  let next = calendar.date(byAdding: .day, value: 7, to: start) else { continue }
            let inWeek = days.filter { $0.date >= start && $0.date < next }
            let average = inWeek.isEmpty
                ? nil
                : inWeek.reduce(0) { $0 + $1.load } / Double(inWeek.count) * displayFactor
            result.append(Week(start: start, averageEffort: average,
                               baseAtEnd: inWeek.last.map { $0.chronic * displayFactor },
                               isCurrent: offset == 0, observedDays: inWeek.count))
        }
        return result
    }

    // MARK: - Drivers

    /// The seven days ending on `day` (inclusive): the three hardest scored workouts and how many days held any workout.
    public func driverWeek(endingOn day: Date) -> DriverWeek {
        let last = calendar.startOfDay(for: day)
        let first = calendar.date(byAdding: .day, value: -6, to: last) ?? last
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        let inWindow = workouts.filter { $0.start >= first && $0.start < end }
        let ranked = inWindow
            .compactMap { workout -> (Workout, Double)? in
                guard let strain = workout.strain, strain > 0 else { return nil }
                return (workout, strain)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.start > $1.0.start }
            .prefix(Self.driverCount)
            .map { workout, strain -> Driver in
                let effort = strain * displayFactor
                return Driver(workout: workout, effort: effort, fraction: min(max(effort / 21, 0), 1))
            }
        let trainingDays = Set(inWindow.map { calendar.startOfDay(for: $0.start) }).count
        return DriverWeek(first: first, last: last, drivers: Array(ranked), trainingDays: trainingDays)
    }

    // MARK: - Sport mix

    /// Each sport's share of the summed workout strain over the `mixWindowDays` ending on `day` (the newest day by default):
    /// the top three sports and the rest as "Other". Empty when no scored workout is in the window.
    public func sportMix(endingOn day: Date? = nil) -> [SportShare] {
        guard let reference = day ?? latest?.date else { return [] }
        let last = calendar.startOfDay(for: reference)
        guard let first = calendar.date(byAdding: .day, value: -(Self.mixWindowDays - 1), to: last),
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        var totals: [String: (name: String, strain: Double)] = [:]
        for workout in workouts where workout.start >= first && workout.start < end {
            guard let strain = workout.strain, strain > 0 else { continue }
            let name = workout.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            totals[key, default: (name, 0)].strain += strain
        }
        let sum = totals.values.reduce(0) { $0 + $1.strain }
        guard sum > 0 else { return [] }

        // "Other" is the overflow bucket, so a sport literally called Other joins it rather than ranking as a sport.
        let named = totals.filter { $0.key != "other" }.values
            .sorted { $0.strain != $1.strain ? $0.strain > $1.strain : $0.name < $1.name }
        let top = Array(named.prefix(Self.mixSportCount))
        let otherStrain = sum - top.reduce(0) { $0 + $1.strain }

        var entries: [(name: String, isOther: Bool, strain: Double)] = top.map { ($0.name, false, $0.strain) }
        if otherStrain > sum * 1e-9 { entries.append(("Other", true, otherStrain)) }

        let fractions = entries.map { $0.strain / sum }
        let percents = Self.largestRemainder(fractions)
        return zip(entries.indices, entries).map { index, entry in
            SportShare(name: entry.name, isOther: entry.isOther, fraction: fractions[index], percent: percents[index])
        }
    }

    /// Whole percents of `fractions` (summing to 1) that add up to exactly 100.
    static func largestRemainder(_ fractions: [Double]) -> [Int] {
        let exact = fractions.map { $0 * 100 }
        var floors = exact.map { Int($0.rounded(.down)) }
        var shortfall = 100 - floors.reduce(0, +)
        let order = exact.indices.sorted {
            let a = exact[$0] - Double(floors[$0]), b = exact[$1] - Double(floors[$1])
            return a != b ? a > b : $0 < $1
        }
        var index = 0
        while shortfall > 0, !order.isEmpty {
            floors[order[index % order.count]] += 1
            shortfall -= 1
            index += 1
        }
        return floors
    }

    // MARK: - Comparison

    private static func makeComparison(days: [Day], workouts: [Workout], newest: Date, calendar: Calendar,
                                   displayFactor: Double) -> Comparison? {
        let span = comparisonWindowDays
        guard let recentFirst = calendar.date(byAdding: .day, value: -(span - 1), to: newest),
              let previousFirst = calendar.date(byAdding: .day, value: -span, to: recentFirst),
              let end = calendar.date(byAdding: .day, value: 1, to: newest) else { return nil }
        let recent = days.filter { $0.date >= recentFirst && $0.date < end }
        let previous = days.filter { $0.date >= previousFirst && $0.date < recentFirst }
        guard !recent.isEmpty, previous.count >= minimumComparisonDays else { return nil }

        func mean(_ values: [Day]) -> Double {
            values.reduce(0) { $0 + $1.load } / Double(values.count) * displayFactor
        }
        func trainingDays(from lower: Date, to upper: Date) -> Int {
            Set(workouts.filter { $0.start >= lower && $0.start < upper }
                .map { calendar.startOfDay(for: $0.start) }).count
        }
        // Ties go to the newest day.
        guard let biggest = recent.reduce(nil as Day?, { best, day in
            guard let best else { return day }
            return day.load >= best.load ? day : best
        }) else { return nil }

        let hasWorkouts = !workouts.isEmpty
        return Comparison(
            averageEffort: mean(recent), previousAverageEffort: mean(previous),
            trainingDays: hasWorkouts ? trainingDays(from: recentFirst, to: end) : nil,
            previousTrainingDays: hasWorkouts ? trainingDays(from: previousFirst, to: recentFirst) : nil,
            biggestDay: .init(date: biggest.date, effort: biggest.load * displayFactor))
    }

    // MARK: - When there is no model

    /// Why there is no load estimate, in terms a person can act on.
    public enum Gap: Sendable, Equatable {
        /// No daily Effort has been recorded for this source.
        case noHistory
        /// History exists but is shorter than the minimum; `remaining` more days of Effort are needed.
        case needsMoreDays(remaining: Int)
        /// There is history, but the selected end day has no Effort value yet.
        case effortNotReady
        /// The history cannot be modeled (a bad value or a duplicated day).
        case unusable
    }

    /// The gap behind an unavailable result, or nil when the model is available.
    ///
    /// The engine reports a target day with no Effort as "not enough contiguous days" with a count of zero, however much
    /// history sits behind it, which reads as "needs 14 more days" for someone with months of data. This reads the same
    /// history the engine was given and names that case for what it is.
    public static func gap(result: TrainingLoadEngine.Result, history: [TrainingLoadEngine.DailyLoad],
                           targetDay: String, configuration: TrainingLoadEngine.Configuration = .standard) -> Gap? {
        guard !result.isAvailable else { return nil }
        let observed = history.filter { $0.load != nil }.count
        let targetHasEffort = history.contains { $0.day == targetDay && $0.load != nil }
        switch result.unavailableReason {
        case .noData:
            return .noHistory
        case .missingTargetDay:
            return observed > 0 ? .effortNotReady : .noHistory
        case .notEnoughContiguousDays:
            if !targetHasEffort { return observed > 0 ? .effortNotReady : .noHistory }
            return .needsMoreDays(remaining: max(1, configuration.minimumDays - result.contiguousDays))
        case .invalidConfiguration, .invalidDay, .duplicateDay, .invalidLoad, nil:
            return .unusable
        }
    }

    /// Calendar days from one `YYYY-MM-DD` day to another (negative when it is earlier), or nil for a malformed day.
    /// Timezone-free, so a label built from it never moves with the device's clock.
    public static func daySpan(from start: String, to end: String) -> Int? {
        guard let a = Self.ordinal(start), let b = Self.ordinal(end) else { return nil }
        return b - a
    }

    private static func ordinal(_ day: String) -> Int? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let value = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: value)) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }
}
