import Foundation
import WhoopProtocol

/// The pauses of one workout: the closed stretches the person paused for, plus the pause still open.
///
/// A pause is a statement about wall-clock time, so every window the ledger describes is in Unix seconds and
/// every question it answers is pure: how much of a span was active, whether one second was paused, which
/// heart-rate readings belong to an active stretch. The live session, the saved workout's detail screen, the
/// rescore pass and the Health write-back all ask this one type, so they cannot disagree about what was paused.
///
/// Toggles are idempotent: pausing an already paused workout, or resuming one that is running, changes nothing
/// and reports `false`.
public struct WorkoutPauseLedger: Codable, Equatable, Sendable {

    /// One closed pause, `start...end` in Unix seconds.
    public struct Interval: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = max(start, end)
        }

        private enum CodingKeys: String, CodingKey { case start, end }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(start: try container.decode(Double.self, forKey: .start),
                      end: try container.decode(Double.self, forKey: .end))
        }

        /// The first whole second after the person paused. A reading stamped with this second or earlier was
        /// taken before the pause.
        var firstPausedSecond: Int { Int(start.rounded(.down)) + 1 }
        /// The whole second the person resumed in. A reading stamped with it is active again.
        var resumedSecond: Int { Int(end.rounded(.down)) }
        /// Whether the pause covers at least one whole second of readings.
        var coversASecond: Bool { firstPausedSecond < resumedSecond }
    }

    public private(set) var intervals: [Interval]
    /// When the pause that has not ended began, or nil while the workout is running.
    public private(set) var openSince: Double?

    public init(intervals: [Interval] = [], openSince: Double? = nil) {
        self.intervals = Self.sanitized(intervals)
        if let openSince, openSince.isFinite {
            self.openSince = max(openSince, self.intervals.last?.end ?? openSince)
        } else {
            self.openSince = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case intervals, openSince }

    /// A persisted ledger is untrusted input: drop non-finite entries, order them and merge overlaps.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            intervals: try container.decodeIfPresent([Interval].self, forKey: .intervals) ?? [],
            openSince: try container.decodeIfPresent(Double.self, forKey: .openSince))
    }

    private static func sanitized(_ raw: [Interval]) -> [Interval] {
        // A pause with no length is no pause: dropping it keeps `hasPauses` honest.
        let finite = raw.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var merged: [Interval] = []
        for interval in finite {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    // MARK: State

    public var isPaused: Bool { openSince != nil }
    /// True once the workout has been paused at all, including a pause still open.
    public var hasPauses: Bool { !intervals.isEmpty || openSince != nil }

    /// Start a pause at `time`. Returns false (and changes nothing) when one is already open or `time` is not a
    /// real moment. A clock that stepped backwards cannot start a pause before the last one ended.
    @discardableResult
    public mutating func pause(at time: Double) -> Bool {
        guard openSince == nil, time.isFinite else { return false }
        openSince = max(time, intervals.last?.end ?? time)
        return true
    }

    /// End the open pause at `time`. Returns false (and changes nothing) when the workout is not paused.
    @discardableResult
    public mutating func resume(at time: Double) -> Bool {
        guard let start = openSince, time.isFinite else { return false }
        intervals = Self.sanitized(intervals + [Interval(start: start, end: time)])
        openSince = nil
        return true
    }

    /// The ledger with any open pause ended at `time`: what a finished workout keeps.
    public func closed(at time: Double) -> WorkoutPauseLedger {
        var copy = self
        copy.resume(at: time)
        return copy
    }

    /// The ledger with an open pause forgotten: a workout ended while paused stops at the moment it was paused.
    public func droppingOpenPause() -> WorkoutPauseLedger {
        WorkoutPauseLedger(intervals: intervals, openSince: nil)
    }

    // MARK: Time

    /// Seconds of `start...end` spent paused, counting an open pause up to `end`.
    public func pausedSeconds(from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        var total = 0.0
        for interval in intervals {
            total += max(0, min(interval.end, end) - max(interval.start, start))
        }
        if let openSince { total += max(0, end - max(openSince, start)) }
        return total
    }

    /// Seconds of `start...end` spent running: the elapsed time the timer shows and the duration a saved
    /// workout keeps.
    public func activeSeconds(from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        return max(0, end - start - pausedSeconds(from: start, to: end))
    }

    // MARK: Readings

    /// Whether a reading stamped `second` was taken during a pause. The boundary seconds belong to the active
    /// stretch: a reading in the second the person paused or resumed is kept.
    public func isPausedSecond(_ second: Int) -> Bool {
        if let openSince, second >= Int(openSince.rounded(.down)) + 1 { return true }
        return intervals.contains { $0.coversASecond && second >= $0.firstPausedSecond && second < $0.resumedSecond }
    }

    /// Whether a pause lies between two active readings, so the stretch from `earlier` to `later` was not
    /// continuous. A pause too short to cover a whole second of readings does not separate them.
    public func separates(_ earlier: Int, _ later: Int) -> Bool {
        guard later > earlier else { return false }
        return intervals.contains {
            $0.coversASecond && $0.firstPausedSecond > earlier && $0.resumedSecond <= later
        }
    }

    /// The readings that belong to active stretches, split wherever a pause separated them. Readings stamped
    /// during a pause are dropped. A ledger with no pauses returns the readings as one stretch, untouched.
    public func segments(of samples: [HRSample]) -> [[HRSample]] {
        guard !samples.isEmpty else { return [] }
        guard hasPauses else { return [samples] }
        var result: [[HRSample]] = []
        var current: [HRSample] = []
        var previousTs: Int?
        for sample in samples.sorted(by: { $0.ts == $1.ts ? $0.bpm < $1.bpm : $0.ts < $1.ts })
        where !isPausedSecond(sample.ts) {
            if let previousTs, separates(previousTs, sample.ts), !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(sample)
            previousTs = sample.ts
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The readings that belong to active stretches, in order, with the paused ones removed.
    public func activeSamples(_ samples: [HRSample]) -> [HRSample] {
        guard hasPauses else { return samples }
        return samples.filter { !isPausedSecond($0.ts) }
    }
}

// MARK: - Scoring over active stretches

extension StrainScorerV2 {

    /// Activity strain of a workout recorded in several uninterrupted stretches. Each stretch is walked with the
    /// same interval kernel as ``strain(_:maxHR:restingHR:mode:)``, so nothing is credited across a pause, and the
    /// loads and coverage add up before the score is formed. With one stretch the result equals `strain` over it.
    public static func activityStrain(segments: [[HRSample]],
                                      maxHR: Double? = nil,
                                      restingHR: Double = defaultRestingHR) -> Double? {
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
        guard effectiveMax.isFinite, restingHR.isFinite, effectiveMax > restingHR else { return nil }
        let sorted = segments.map(sortedValidSamples)
        guard sorted.reduce(0, { $0 + $1.count }) >= minReadings else { return nil }
        var load = 0.0
        var coverage = 0
        for segment in sorted {
            let part = cardiovascularKernel(segment, effectiveMax: effectiveMax, restingHR: restingHR,
                                            requiresMinimumReadings: false)
            load += part.load
            coverage += part.coverageSeconds
        }
        guard coverage >= minCoverageSeconds else { return nil }
        return storedValue(fromDisplay: displayStrain(forEffectiveLoad: load))
    }
}

extension Calories {

    /// Bout energy over several uninterrupted stretches: each stretch is weighted by its own sample spacing, so a
    /// pause is never credited as time at the last reading's rate.
    public static func estimateBoutCalories(segments: [[HRSample]],
                                            profile: UserProfile,
                                            hrmax: Double?,
                                            restingHR: Double?) -> (Double, Double) {
        var kcal = 0.0
        for segment in segments where !segment.isEmpty {
            kcal += estimateBoutCalories(segment, profile: profile, hrmax: hrmax, restingHR: restingHR).0
        }
        return (kcal, kcal * 4.184)
    }
}
