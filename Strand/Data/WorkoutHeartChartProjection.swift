import Foundation
import WhoopProtocol
import WhoopStore

/// A render-budgeted projection for the live workout heart chart.
///
/// The source session remains authoritative and unmodified. Presentation reads only the requested trailing
/// time window, collapses duplicate samples within the same integer second, and preserves local extrema when
/// reducing a long session to a bounded number of points. This makes the label "last 3 hours" literal instead
/// of meaning "last 360 callbacks", while preventing one long workout from growing the SwiftUI path forever.
struct WorkoutHeartChartProjection: Equatable, Sendable {
    static let defaultWindowSeconds = 3 * 60 * 60
    static let defaultMaximumPoints = 360

    let values: [Double]
    let range: ClosedRange<Double>
    let firstSampleAt: Int?
    let lastSampleAt: Int?

    var observedSeconds: Int {
        guard let firstSampleAt, let lastSampleAt else { return 0 }
        return max(0, lastSampleAt - firstSampleAt)
    }

    static func make(
        samples: [HRSample],
        now: Int = Int(Date().timeIntervalSince1970),
        windowSeconds: Int = defaultWindowSeconds,
        maximumPoints: Int = defaultMaximumPoints
    ) -> WorkoutHeartChartProjection {
        let safeWindow = max(1, windowSeconds)
        let lowerBound = now - safeWindow

        // The live sinks can publish more than once inside the same integer second. One second is the chart's
        // useful maximum resolution; last-write-wins avoids visually and statistically overweighting a busy
        // callback second while retaining the freshest smoothed value for that second.
        var bySecond: [Int: Int] = [:]
        for sample in samples where sample.ts >= lowerBound && sample.ts <= now
            && (30...240).contains(sample.bpm) {
            bySecond[sample.ts] = sample.bpm
        }

        let ordered = bySecond
            .map { HRSample(ts: $0.key, bpm: $0.value) }
            .sorted { $0.ts < $1.ts }
        let rendered = extremaPreservingSample(ordered, maximumPoints: maximumPoints)
        let values = rendered.map { Double($0.bpm) }

        return WorkoutHeartChartProjection(
            values: values,
            range: displayRange(values),
            firstSampleAt: rendered.first?.ts,
            lastSampleAt: rendered.last?.ts
        )
    }

    /// Keep the first/last sample and the min/max point from each chronological bucket. Evenly taking every
    /// Nth point can erase the exact spike or trough a workout chart exists to communicate.
    nonisolated static func extremaPreservingSample(
        _ samples: [HRSample],
        maximumPoints: Int
    ) -> [HRSample] {
        let limit = max(2, maximumPoints)
        guard samples.count > limit else { return samples }
        guard let first = samples.first, let last = samples.last else { return [] }

        let interior = Array(samples.dropFirst().dropLast())
        let interiorBudget = limit - 2
        guard interiorBudget > 0, !interior.isEmpty else { return [first, last] }

        // Two points per bucket (min + max), with chronological ordering inside each bucket.
        let bucketCount = max(1, interiorBudget / 2)
        let bucketSize = max(1, Int(ceil(Double(interior.count) / Double(bucketCount))))
        var result: [HRSample] = [first]
        result.reserveCapacity(limit)

        var start = 0
        while start < interior.count && result.count < limit - 1 {
            let end = min(interior.count, start + bucketSize)
            let bucket = interior[start..<end]
            guard let minimum = bucket.enumerated().min(by: { $0.element.bpm < $1.element.bpm }),
                  let maximum = bucket.enumerated().max(by: { $0.element.bpm < $1.element.bpm })
            else { break }

            let candidates: [HRSample]
            if minimum.offset == maximum.offset {
                candidates = [minimum.element]
            } else if minimum.offset < maximum.offset {
                candidates = [minimum.element, maximum.element]
            } else {
                candidates = [maximum.element, minimum.element]
            }
            for candidate in candidates where result.count < limit - 1 {
                result.append(candidate)
            }
            start = end
        }

        result.append(last)
        return result
    }

    /// Auto-fit around observed values with a practical physiological clamp. A fixed 100...180 range clipped
    /// easy/recovery sessions and high-intensity peaks, making a valid chart look flat or truncated.
    nonisolated static func displayRange(_ values: [Double]) -> ClosedRange<Double> {
        guard let minimum = values.min(), let maximum = values.max() else { return 40...180 }
        let observedSpan = max(0, maximum - minimum)
        let padding = max(6, observedSpan * 0.12)
        var lower = max(30, floor(minimum - padding))
        var upper = min(240, ceil(maximum + padding))

        if upper - lower < 20 {
            let midpoint = (minimum + maximum) / 2
            lower = max(30, floor(midpoint - 10))
            upper = min(240, ceil(midpoint + 10))
            if upper - lower < 20 {
                if lower == 30 { upper = min(240, lower + 20) }
                else if upper == 240 { lower = max(30, upper - 20) }
            }
        }
        return lower...upper
    }
}

/// Incremental live-chart state. It retains at most the trailing three hours of canonical one-second
/// samples as constant-size minute summaries, and publishes at most 360 extrema-preserving points. Updating
/// the live chart therefore has a fixed memory/work budget proportional to retained minutes, not callbacks.
struct WorkoutHeartChartAccumulator: Sendable {
    private struct MinuteBucket: Sendable {
        let minute: Int
        private(set) var first: HRSample
        private(set) var last: HRSample
        private var completedMinimum: HRSample?
        private var completedMaximum: HRSample?

        init(minute: Int, sample: HRSample) {
            self.minute = minute
            first = sample
            last = sample
            completedMinimum = nil
            completedMaximum = nil
        }

        mutating func ingest(_ sample: HRSample) -> Bool {
            guard sample.ts >= last.ts else { return false }
            if sample.ts == last.ts {
                last = sample
                if first.ts == sample.ts { first = sample }
                return true
            }

            includeCompleted(last)
            last = sample
            return true
        }

        /// The moving window can enter the first retained minute. Since the bucket intentionally does not
        /// retain every second, discard its older aggregate state and keep only the newest in-window sample.
        /// This fails closed (never renders data older than the requested window) at a maximum cost of one
        /// boundary minute of chart detail.
        mutating func trim(before lowerBound: Int) -> Bool {
            guard last.ts >= lowerBound else { return false }
            guard first.ts < lowerBound else { return true }
            self = MinuteBucket(minute: minute, sample: last)
            return true
        }

        var extrema: [HRSample] {
            // A minute boundary can carry a meaningful step even when its first/last values are not
            // that minute's extrema. Retain the explicit first/last contract alongside min/max while
            // keeping the bucket constant-size.
            var candidates = [first, last]
            if let completedMinimum { candidates.append(completedMinimum) }
            if let completedMaximum { candidates.append(completedMaximum) }
            candidates.sort { lhs, rhs in
                lhs.ts == rhs.ts ? lhs.bpm < rhs.bpm : lhs.ts < rhs.ts
            }
            var unique: [HRSample] = []
            unique.reserveCapacity(4)
            for candidate in candidates {
                if unique.last?.ts == candidate.ts { unique[unique.count - 1] = candidate }
                else { unique.append(candidate) }
            }
            return unique
        }

        var retainedSampleCount: Int {
            Set([first.ts, last.ts, completedMinimum?.ts, completedMaximum?.ts].compactMap { $0 }).count
        }

        private mutating func includeCompleted(_ sample: HRSample) {
            if let current = completedMinimum {
                if Self.minimumOrder(sample, current) { completedMinimum = sample }
            } else {
                completedMinimum = sample
            }
            if let current = completedMaximum {
                if Self.maximumOrder(current, sample) { completedMaximum = sample }
            } else {
                completedMaximum = sample
            }
        }

        private static func minimumOrder(_ lhs: HRSample, _ rhs: HRSample) -> Bool {
            lhs.bpm == rhs.bpm ? lhs.ts < rhs.ts : lhs.bpm < rhs.bpm
        }

        private static func maximumOrder(_ lhs: HRSample, _ rhs: HRSample) -> Bool {
            lhs.bpm == rhs.bpm ? lhs.ts > rhs.ts : lhs.bpm < rhs.bpm
        }
    }

    private let windowSeconds: Int
    private let maximumPoints: Int
    private var buckets: [MinuteBucket] = []

    init(
        samples: [HRSample] = [],
        windowSeconds: Int = WorkoutHeartChartProjection.defaultWindowSeconds,
        maximumPoints: Int = WorkoutHeartChartProjection.defaultMaximumPoints
    ) {
        self.windowSeconds = max(1, windowSeconds)
        self.maximumPoints = max(2, maximumPoints)
        for sample in samples.sorted(by: { $0.ts < $1.ts }) { _ = ingest(sample) }
    }

    @discardableResult
    mutating func ingest(_ sample: HRSample) -> Bool {
        guard sample.ts > 0, (30...240).contains(sample.bpm) else { return false }
        let minute = sample.ts / 60
        if buckets.last?.minute == minute {
            guard buckets[buckets.count - 1].ingest(sample) else { return false }
        } else {
            guard buckets.last.map({ minute > $0.minute }) ?? true else { return false }
            buckets.append(MinuteBucket(minute: minute, sample: sample))
        }

        let lowerBound = sample.ts - windowSeconds
        while let first = buckets.first, first.last.ts < lowerBound {
            buckets.removeFirst()
        }
        if !buckets.isEmpty, !buckets[0].trim(before: lowerBound) {
            buckets.removeFirst()
        }
        return true
    }

    var retainedSampleCount: Int { buckets.reduce(0) { $0 + $1.retainedSampleCount } }
    var retainedMinuteCount: Int { buckets.count }

    var projection: WorkoutHeartChartProjection {
        guard let first = buckets.first?.first,
              let last = buckets.last?.last else {
            return WorkoutHeartChartProjection(
                values: [], range: WorkoutHeartChartProjection.displayRange([]),
                firstSampleAt: nil, lastSampleAt: nil
            )
        }
        var candidates = buckets.flatMap(\.extrema)
        candidates.append(first)
        candidates.append(last)
        candidates.sort { lhs, rhs in lhs.ts == rhs.ts ? lhs.bpm < rhs.bpm : lhs.ts < rhs.ts }
        var unique: [HRSample] = []
        unique.reserveCapacity(candidates.count)
        for candidate in candidates {
            if unique.last?.ts == candidate.ts { unique[unique.count - 1] = candidate }
            else { unique.append(candidate) }
        }
        let rendered = WorkoutHeartChartProjection.extremaPreservingSample(
            unique, maximumPoints: maximumPoints
        )
        let values = rendered.map { Double($0.bpm) }
        return WorkoutHeartChartProjection(
            values: values,
            range: WorkoutHeartChartProjection.displayRange(values),
            firstSampleAt: rendered.first?.ts,
            lastSampleAt: rendered.last?.ts
        )
    }
}
