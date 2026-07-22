import Foundation
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
