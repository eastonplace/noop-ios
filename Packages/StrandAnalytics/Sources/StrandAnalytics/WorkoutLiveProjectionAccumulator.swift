import Foundation
import WhoopProtocol

/// Incremental, exact-equivalent live projection for a growing workout HR stream. The active workout screen
/// still receives every sample; this accumulator prevents Lock Screen/Dynamic Island calories and zone data
/// from sorting and rescanning the complete workout every projection interval.
public struct WorkoutLiveProjectionAccumulator: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let caloriesKcal: Double
        public let zoneSeconds: [Double]
        public let hrTrace: [Int]
        public let sampleCount: Int
        public let lastTimestamp: Int?
    }

    private static let traceLimit = 48
    private static let largestMedianGap = 299

    private let profile: UserProfile
    private let hrmax: Double?
    private let restingHR: Double?
    private let zoneSet: HRZoneSet

    private var lastSample: HRSample?
    private var sampleCount = 0
    private var totalCalories = 0.0
    private var trace: [Int] = []

    private var gapHistogramByBucket = Array(
        repeating: Array(repeating: 0, count: largestMedianGap + 1),
        count: 6
    )
    private var largeOrNonPositiveGapCountByBucket = Array(repeating: 0, count: 6)
    private var plausibleGapHistogram = Array(repeating: 0, count: largestMedianGap + 1)
    private var plausibleGapCount = 0

    public init(
        samples: [HRSample] = [],
        profile: UserProfile,
        hrmax: Double?,
        restingHR: Double?,
        zoneSet: HRZoneSet
    ) {
        self.profile = profile
        self.hrmax = hrmax
        self.restingHR = restingHR
        self.zoneSet = zoneSet
        rebuild(samples)
    }

    @discardableResult
    public mutating func append(_ sample: HRSample) -> Bool {
        guard let previous = lastSample else {
            addFirst(sample)
            return true
        }
        guard sample.ts >= previous.ts else { return false }

        totalCalories -= calorieContribution(previous, duration: 1)
        let gap = sample.ts - previous.ts
        let duration = gap > 0 ? min(Double(gap), WorkoutDetector.mergeGapS) : 1
        totalCalories += calorieContribution(previous, duration: duration)
        totalCalories += calorieContribution(sample, duration: 1)

        addGap(gap, bucket: zoneBucket(for: previous.bpm))
        lastSample = sample
        sampleCount += 1
        trace.append(sample.bpm)
        if trace.count > Self.traceLimit { trace.removeFirst(trace.count - Self.traceLimit) }
        return true
    }

    public func snapshot() -> Snapshot {
        let median = medianGap()
        var seconds = Array(repeating: 0.0, count: 6)
        for bucket in 0..<6 {
            var total = Double(largeOrNonPositiveGapCountByBucket[bucket]) * median
            let histogram = gapHistogramByBucket[bucket]
            for gap in 1...Self.largestMedianGap where histogram[gap] > 0 {
                total += Double(histogram[gap]) * min(Double(gap), median)
            }
            seconds[bucket] = total
        }
        if let lastSample { seconds[zoneBucket(for: lastSample.bpm)] += median }
        return Snapshot(
            caloriesKcal: max(0, totalCalories),
            zoneSeconds: Array(seconds.dropFirst()),
            hrTrace: trace,
            sampleCount: sampleCount,
            lastTimestamp: lastSample?.ts
        )
    }

    private mutating func rebuild(_ input: [HRSample]) {
        lastSample = nil
        sampleCount = 0
        totalCalories = 0
        trace.removeAll(keepingCapacity: true)
        gapHistogramByBucket = Array(
            repeating: Array(repeating: 0, count: Self.largestMedianGap + 1),
            count: 6
        )
        largeOrNonPositiveGapCountByBucket = Array(repeating: 0, count: 6)
        plausibleGapHistogram = Array(repeating: 0, count: Self.largestMedianGap + 1)
        plausibleGapCount = 0
        for sample in input.sorted(by: { $0.ts < $1.ts }) { _ = append(sample) }
    }

    private mutating func addFirst(_ sample: HRSample) {
        lastSample = sample
        sampleCount = 1
        totalCalories = calorieContribution(sample, duration: 1)
        trace = [sample.bpm]
    }

    private mutating func addGap(_ gap: Int, bucket: Int) {
        if gap > 0 && gap <= Self.largestMedianGap {
            gapHistogramByBucket[bucket][gap] += 1
            plausibleGapHistogram[gap] += 1
            plausibleGapCount += 1
        } else {
            largeOrNonPositiveGapCountByBucket[bucket] += 1
        }
    }

    private func medianGap() -> Double {
        guard plausibleGapCount > 0 else { return 1 }
        let target = plausibleGapCount / 2
        var seen = 0
        for gap in 1...Self.largestMedianGap {
            seen += plausibleGapHistogram[gap]
            if seen > target { return Double(max(gap, 1)) }
        }
        return 1
    }

    private func zoneBucket(for bpm: Int) -> Int {
        zoneSet.zoneNumber(forBPM: Double(bpm))
    }

    private func calorieContribution(_ sample: HRSample, duration: Double) -> Double {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170
        let age = profile.age > 0 ? profile.age : 30
        let coefficients = Calories.resolveCoeffs(profile.sex)
        let effectiveMax = hrmax ?? 220
        let effectiveResting = restingHR ?? 60
        let threshold = effectiveResting
            + Calories.activeHRRFraction * (effectiveMax - effectiveResting)
        if Double(sample.bpm) < threshold {
            return Calories.restingKcalPerS(
                coefficients, weightKg: weightKg, heightCm: heightCm, age: age
            ) * duration
        }
        return Calories.activeKcalPerS(
            coefficients,
            hr: Double(sample.bpm),
            hrmax: effectiveMax,
            weightKg: weightKg,
            age: age
        ) * duration
    }
}
