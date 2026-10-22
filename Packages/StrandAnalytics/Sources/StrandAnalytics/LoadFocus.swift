import Foundation

/// Load focus: how much of the last four weeks of workout load was easy aerobic, hard aerobic or anaerobic.
///
/// Per-workout minutes in heart-rate zones 1...5 (`HRZones`) are weighted with the Edwards zone weights Effort uses
/// (`StrainScorer.zoneWeights`), so a hard minute counts for more than an easy one, then grouped into three buckets.
/// An ESTIMATE from heart rate: without lactate or power data it is a proxy, not a lab measurement. Workouts only.
public enum LoadFocus {
    public enum Bucket: CaseIterable, Sendable {
        case lowAerobic, highAerobic, anaerobic

        public var zones: ClosedRange<Int> {
            switch self {
            case .lowAerobic: 1...2
            case .highAerobic: 3...4
            case .anaerobic: 5...5
            }
        }

        /// A broad endurance split, in whole percent of the weighted load. Not a prescription.
        public var target: ClosedRange<Int> {
            switch self {
            case .lowAerobic: 35...55
            case .highAerobic: 25...45
            case .anaerobic: 5...15
            }
        }
    }

    public enum Status: Sendable, Equatable {
        case inRange
        /// Whole percentage points under / over the target range.
        case below(Int)
        case above(Int)

        public var points: Int {
            switch self {
            case .inRange: 0
            case .below(let n), .above(let n): n
            }
        }
    }

    /// A workout's start and its minutes in zones 1...5; nil when it carries no heart rate.
    public struct Workout: Sendable, Equatable {
        public let start: Date
        public let zoneMinutes: [Double]?
        public init(start: Date, zoneMinutes: [Double]?) {
            self.start = start
            self.zoneMinutes = zoneMinutes
        }
    }

    /// Weighted load per bucket, in `Bucket.allCases` order.
    public struct Split: Sendable, Equatable {
        public let load: [Double]
        public var total: Double { load.reduce(0, +) }
        public func fraction(_ bucket: Bucket) -> Double {
            let t = total
            return t > 0 ? load[Bucket.allCases.firstIndex(of: bucket)!] / t : 0
        }
    }

    public struct Share: Sendable, Equatable {
        public let bucket: Bucket
        public let fraction: Double
        /// Whole percent; the three sum to exactly 100.
        public let percent: Int
        public let status: Status
    }

    /// One seven-day block; `start` is its first instant.
    public struct Week: Sendable, Equatable {
        public let start: Date
        public let split: Split
    }

    public struct Summary: Sendable, Equatable {
        /// Low aerobic, high aerobic, anaerobic.
        public let shares: [Share]
        /// Oldest first, the last four seven-day blocks.
        public let weeks: [Week]
        public let workoutCount: Int
        /// The share furthest outside its target, if any.
        public var largestGap: Share? {
            shares.filter { $0.status.points > 0 }.max { $0.status.points < $1.status.points }
        }
    }

    public enum Result: Sendable, Equatable {
        case insufficient(workoutsWithHR: Int)
        case ready(Summary)
    }

    public static let windowDays = 28
    public static let minimumWorkouts = 3

    /// The split of one workout's zone minutes, or nil when they hold no weighted load.
    public static func split(zoneMinutes: [Double]) -> Split? {
        guard zoneMinutes.count == 5 else { return nil }
        let weights = StrainScorer.zoneWeights
        let load = Bucket.allCases.map { bucket in
            bucket.zones.reduce(0.0) { sum, zone in
                let minutes = zoneMinutes[zone - 1]
                return sum + (minutes.isFinite && minutes > 0 ? minutes * weights[zone - 1] : 0)
            }
        }
        let split = Split(load: load)
        return split.total > 0 ? split : nil
    }

    /// The four weeks ending at `end` (exclusive: pass the start of the day after the anchor day).
    public static func evaluate(workouts: [Workout], through end: Date, calendar: Calendar = .current) -> Result {
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: end) ?? end }
        let starts = (0..<4).map { day(7 * (4 - $0)) }
        let measured: [(start: Date, split: Split)] = workouts.compactMap { workout in
            guard workout.start >= starts[0], workout.start < end,
                  let split = workout.zoneMinutes.flatMap(split(zoneMinutes:)) else { return nil }
            return (workout.start, split)
        }
        guard measured.count >= minimumWorkouts else { return .insufficient(workoutsWithHR: measured.count) }

        func sum(_ items: [(start: Date, split: Split)]) -> Split {
            Split(load: Bucket.allCases.indices.map { i in items.reduce(0) { $0 + $1.split.load[i] } })
        }
        let weeks = starts.indices.map { i -> Week in
            let upper = i + 1 < starts.count ? starts[i + 1] : end
            return Week(start: starts[i], split: sum(measured.filter { $0.start >= starts[i] && $0.start < upper }))
        }
        let total = sum(measured)
        let percents = wholePercents(Bucket.allCases.map { total.fraction($0) })
        let shares = Bucket.allCases.enumerated().map { i, bucket in
            Share(bucket: bucket, fraction: total.fraction(bucket), percent: percents[i],
                  status: status(percent: percents[i], target: bucket.target))
        }
        return .ready(Summary(shares: shares, weeks: weeks, workoutCount: measured.count))
    }

    static func status(percent: Int, target: ClosedRange<Int>) -> Status {
        if percent < target.lowerBound { return .below(target.lowerBound - percent) }
        if percent > target.upperBound { return .above(percent - target.upperBound) }
        return .inRange
    }

    /// Largest-remainder rounding, so the shown percentages sum to exactly 100.
    static func wholePercents(_ fractions: [Double]) -> [Int] {
        var floors = fractions.map { Int(($0 * 100).rounded(.down)) }
        let order = fractions.indices.sorted {
            (fractions[$0] * 100 - Double(floors[$0])) > (fractions[$1] * 100 - Double(floors[$1]))
        }
        for i in order.prefix(max(0, 100 - floors.reduce(0, +))) { floors[i] += 1 }
        return floors
    }
}
