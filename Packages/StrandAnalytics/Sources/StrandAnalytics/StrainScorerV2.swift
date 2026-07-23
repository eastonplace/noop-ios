import Foundation
import WhoopProtocol

/// Timestamp-aware continuous cardiovascular load for canonical NOOP Strain V2.
public enum StrainScorerV2 {
    public static let version = 2
    public static let minReadings = 20
    public static let minCoverageSeconds = 10 * 60
    public static let maxIntervalSeconds = 90
    public static let defaultRestingHR = 60.0
    public static let displayMaximum = 21.0
    public static let storedMaximum = 100.0
    public static let saturationConstant = 32.0

    public struct DayContext: Equatable, Sendable {
        public let validWornSleepMinutes: Double?
        public let steps: Int?
        public let activeEnergyKcal: Double?
        public let hasWearCoverage: Bool

        public init(validWornSleepMinutes: Double? = nil,
                    steps: Int? = nil,
                    activeEnergyKcal: Double? = nil,
                    hasWearCoverage: Bool = true) {
            self.validWornSleepMinutes = validWornSleepMinutes
            self.steps = steps
            self.activeEnergyKcal = activeEnergyKcal
            self.hasWearCoverage = hasWearCoverage
        }
    }

    public enum Mode: Equatable, Sendable {
        case physiologicalDay(DayContext)
        case activity
    }

    /// Constant-time preview state for a chronological live activity stream.
    ///
    /// The authoritative saved score still runs through ``strain(_:maxHR:restingHR:mode:)`` over the
    /// complete sample array. This accumulator mirrors the activity kernel while a workout is live so
    /// appending one reading never re-sorts or re-walks the entire session. Equal-second readings keep
    /// the maximum BPM, matching the scorer's stable timestamp ordering; older out-of-order readings are
    /// ignored because a live stream cannot incorporate them without giving up constant-time updates.
    public struct ActivityAccumulator: Equatable, Sendable {
        private let effectiveMaxHR: Double
        private let restingHR: Double
        private var currentSecond: Int?
        private var currentSecondMaxBPM = 0
        private var cardiovascularLoad = 0.0
        private var bpmSum = 0
        private var bpmHistogram = Array(repeating: 0, count: 241)

        public private(set) var readingCount = 0
        public private(set) var coverageSeconds = 0
        public private(set) var peakHR: Int?

        public init(maxHR: Double? = nil, restingHR: Double = StrainScorerV2.defaultRestingHR) {
            self.effectiveMaxHR = maxHR
                ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
            self.restingHR = restingHR
        }

        public init<S: Sequence>(samples: S, maxHR: Double? = nil,
                                 restingHR: Double = StrainScorerV2.defaultRestingHR)
        where S.Element == HRSample {
            self.init(maxHR: maxHR, restingHR: restingHR)
            for sample in samples { append(sample) }
        }

        public var averageHR: Int? {
            guard readingCount > 0 else { return nil }
            return Int((Double(bpmSum) / Double(readingCount)).rounded())
        }

        public var strain: Double? {
            guard effectiveMaxHR.isFinite, restingHR.isFinite, effectiveMaxHR > restingHR,
                  readingCount >= StrainScorerV2.minReadings,
                  coverageSeconds >= StrainScorerV2.minCoverageSeconds else { return nil }
            return StrainScorerV2.storedValue(
                fromDisplay: StrainScorerV2.displayStrain(forEffectiveLoad: cardiovascularLoad))
        }

        public mutating func append(_ sample: HRSample) {
            guard sample.ts > 0, (30...240).contains(sample.bpm),
                  effectiveMaxHR.isFinite, restingHR.isFinite,
                  effectiveMaxHR > restingHR else { return }

            if let second = currentSecond {
                guard sample.ts >= second else { return }
                if sample.ts == second {
                    currentSecondMaxBPM = max(currentSecondMaxBPM, sample.bpm)
                } else {
                    let delta = sample.ts - second
                    if delta <= StrainScorerV2.maxIntervalSeconds {
                        coverageSeconds += delta
                        let reserve = effectiveMaxHR - restingHR
                        let hrr = min(100, max(0,
                            (Double(currentSecondMaxBPM) - restingHR) / reserve * 100))
                        cardiovascularLoad += StrainScorerV2.loadPerMinute(atHRR: hrr)
                            * Double(delta) / 60.0
                    }
                    currentSecond = sample.ts
                    currentSecondMaxBPM = sample.bpm
                }
            } else {
                currentSecond = sample.ts
                currentSecondMaxBPM = sample.bpm
            }

            readingCount += 1
            bpmSum += sample.bpm
            bpmHistogram[sample.bpm] += 1
            peakHR = max(peakHR ?? sample.bpm, sample.bpm)
        }

        /// Replace the canonical value for the current integer second without increasing reading count or
        /// changing elapsed coverage. Live transports can callback several times inside one second; the
        /// workout session owns one last-write-wins sample for that second and uses this operation to keep
        /// its running average/peak/strain preview equivalent to the eventually persisted sample array.
        @discardableResult
        public mutating func replaceCurrentSecond(with sample: HRSample) -> Bool {
            guard sample.ts > 0, (30...240).contains(sample.bpm),
                  sample.ts == currentSecond,
                  effectiveMaxHR.isFinite, restingHR.isFinite,
                  effectiveMaxHR > restingHR else { return false }

            let replacedBPM = currentSecondMaxBPM
            bpmSum += sample.bpm - replacedBPM
            bpmHistogram[replacedBPM] -= 1
            bpmHistogram[sample.bpm] += 1
            currentSecondMaxBPM = sample.bpm
            peakHR = stride(from: 240, through: 30, by: -1)
                .first(where: { bpmHistogram[$0] > 0 })
            return true
        }
    }

    /// Constant-time physiological-day twin of `ActivityAccumulator`. The cardio
    /// kernel is identical; sleep/steps/energy remain non-additive floors exactly as
    /// in the authoritative batch scorer.
    public struct PhysiologicalDayAccumulator: Equatable, Sendable {
        private let effectiveMaxHR: Double
        private let restingHR: Double
        private var currentSecond: Int?
        private var currentSecondMaxBPM = 0
        private var cardiovascularLoad = 0.0
        public private(set) var readingCount = 0
        public private(set) var coverageSeconds = 0
        public private(set) var rawFrontierTs: Int?
        public private(set) var context: DayContext

        public init(maxHR: Double? = nil, restingHR: Double = StrainScorerV2.defaultRestingHR,
                    context: DayContext = .init()) {
            self.effectiveMaxHR = maxHR
                ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
            self.restingHR = restingHR
            self.context = context
        }

        public init<S: Sequence>(samples: S, maxHR: Double? = nil,
                                 restingHR: Double = StrainScorerV2.defaultRestingHR,
                                 context: DayContext = .init()) where S.Element == HRSample {
            self.init(maxHR: maxHR, restingHR: restingHR, context: context)
            for sample in samples { append(sample) }
        }

        public var strain: Double? {
            guard effectiveMaxHR.isFinite, restingHR.isFinite, effectiveMaxHR > restingHR else { return nil }
            return StrainScorerV2.physiologicalStoredValue(
                cardiovascularLoad: cardiovascularLoad,
                coverageSeconds: coverageSeconds,
                context: context
            )
        }

        public mutating func update(context: DayContext) { self.context = context }

        public mutating func append(_ sample: HRSample) {
            guard sample.ts > 0, (30...240).contains(sample.bpm),
                  effectiveMaxHR.isFinite, restingHR.isFinite,
                  effectiveMaxHR > restingHR else { return }

            if let second = currentSecond {
                guard sample.ts >= second else { return }
                if sample.ts == second {
                    currentSecondMaxBPM = max(currentSecondMaxBPM, sample.bpm)
                } else {
                    let delta = sample.ts - second
                    if delta <= StrainScorerV2.maxIntervalSeconds {
                        coverageSeconds += delta
                        let reserve = effectiveMaxHR - restingHR
                        let hrr = min(100, max(0,
                            (Double(currentSecondMaxBPM) - restingHR) / reserve * 100))
                        cardiovascularLoad += StrainScorerV2.loadPerMinute(atHRR: hrr)
                            * Double(delta) / 60.0
                    }
                    currentSecond = sample.ts
                    currentSecondMaxBPM = sample.bpm
                }
            } else {
                currentSecond = sample.ts
                currentSecondMaxBPM = sample.bpm
            }

            readingCount += 1
            rawFrontierTs = max(rawFrontierTs ?? sample.ts, sample.ts)
        }
    }

    private static let loadAnchors: [(hrr: Double, load: Double)] = [
        (30, 0), (40, 0.05), (60, 0.20), (70, 0.45), (80, 0.70), (90, 1.0),
    ]

    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              mode: Mode) -> Double? {
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
        guard effectiveMax.isFinite, restingHR.isFinite, effectiveMax > restingHR else { return nil }
        let sorted = hr
            .filter { (30...240).contains($0.bpm) }
            .sorted { lhs, rhs in lhs.ts == rhs.ts ? lhs.bpm < rhs.bpm : lhs.ts < rhs.ts }
        return strainSorted(sorted, maxHR: effectiveMax, restingHR: restingHR, mode: mode)
    }

    /// Fast path for already sorted, validated input. The public API remains defensive.
    static func strainSorted<C: RandomAccessCollection>(
        _ sortedValidHR: C,
        maxHR: Double?,
        restingHR: Double,
        mode: Mode
    ) -> Double? where C.Element == HRSample {
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
        guard effectiveMax.isFinite, restingHR.isFinite, effectiveMax > restingHR else { return nil }

        let reserve = effectiveMax - restingHR
        var cardiovascularLoad = 0.0
        var coverageSeconds = 0
        if sortedValidHR.count >= minReadings {
            var index = sortedValidHR.startIndex
            var next = sortedValidHR.index(after: index)
            while next != sortedValidHR.endIndex {
                let earlier = sortedValidHR[index]
                let later = sortedValidHR[next]
                let delta = later.ts - earlier.ts
                if delta > 0, delta <= maxIntervalSeconds {
                    coverageSeconds += delta
                    let hrr = min(100, max(0, (Double(earlier.bpm) - restingHR) / reserve * 100))
                    cardiovascularLoad += loadPerMinute(atHRR: hrr) * Double(delta) / 60.0
                }
                index = next
                next = sortedValidHR.index(after: next)
            }
        }
        let hasCardiovascularCoverage = coverageSeconds >= minCoverageSeconds

        switch mode {
        case .activity:
            guard hasCardiovascularCoverage else { return nil }
            return storedValue(fromDisplay: displayStrain(forEffectiveLoad: cardiovascularLoad))
        case .physiologicalDay(let context):
            return physiologicalStoredValue(cardiovascularLoad: cardiovascularLoad,
                                             coverageSeconds: coverageSeconds,
                                             context: context)
        }
    }

    static func physiologicalStoredValue(cardiovascularLoad: Double, coverageSeconds: Int,
                                         context: DayContext) -> Double? {
        guard context.hasWearCoverage else { return nil }
        let hasCardiovascularCoverage = coverageSeconds >= minCoverageSeconds
        let hasBackgroundEvidence = context.validWornSleepMinutes != nil
            || context.steps != nil
            || context.activeEnergyKcal != nil
        guard hasCardiovascularCoverage || hasBackgroundEvidence else { return nil }
        let sleepLoad = min(sleepSeedCapLoad,
                            max(0, context.validWornSleepMinutes ?? 0) * 0.014)
        let cardioDisplay = displayStrain(
            forEffectiveLoad: (hasCardiovascularCoverage ? cardiovascularLoad : 0) + sleepLoad)
        let stepDisplay = context.steps.map(stepFloor) ?? 0
        let energyDisplay = context.activeEnergyKcal.map(activeEnergyFloor) ?? 0
        return storedValue(fromDisplay: max(cardioDisplay, stepDisplay, energyDisplay))
    }

    public static func loadPerMinute(atHRR hrr: Double) -> Double {
        guard hrr.isFinite else { return 0 }
        if hrr <= loadAnchors[0].hrr { return loadAnchors[0].load }
        if hrr >= loadAnchors[loadAnchors.count - 1].hrr { return loadAnchors[loadAnchors.count - 1].load }
        for (lower, upper) in zip(loadAnchors, loadAnchors.dropFirst()) where hrr <= upper.hrr {
            let fraction = (hrr - lower.hrr) / (upper.hrr - lower.hrr)
            return lower.load + fraction * (upper.load - lower.load)
        }
        return 0
    }

    public static func displayStrain(forEffectiveLoad load: Double) -> Double {
        guard load.isFinite, load > 0 else { return 0 }
        return min(displayMaximum, displayMaximum * (1 - exp(-load / saturationConstant)))
    }

    public static func stepFloor(_ steps: Int) -> Double {
        guard steps > 0 else { return 0 }
        return 7 * (1 - exp(-Double(steps) / 6_000))
    }

    public static func activeEnergyFloor(_ kcal: Double) -> Double {
        guard kcal.isFinite, kcal > 0 else { return 0 }
        return 7 * (1 - exp(-kcal / 500))
    }

    public static func storedValue(fromDisplay display: Double) -> Double {
        min(displayMaximum, max(0, display)) * storedMaximum / displayMaximum
    }

    public static func displayValue(fromStored stored: Double) -> Double {
        min(storedMaximum, max(0, stored)) * displayMaximum / storedMaximum
    }

    private static var sleepSeedCapLoad: Double {
        -saturationConstant * log(1 - 4 / displayMaximum)
    }
}
