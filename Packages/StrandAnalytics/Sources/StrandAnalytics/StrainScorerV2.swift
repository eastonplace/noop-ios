import Foundation
import WhoopProtocol

/// Transparent, timestamp-aware cardiovascular load used by NOOP Strain V2.
///
/// Public scores remain on NOOP's persisted 0...100 axis. `displayValue` and
/// `storedValue` make the 0...21 model boundary explicit without introducing a
/// dependency from StrandAnalytics to the UI-oriented StrandDesign package.
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

    private static let loadAnchors: [(hrr: Double, load: Double)] = [
        (30, 0), (40, 0.05), (60, 0.20), (70, 0.45), (80, 0.70), (90, 1.0),
    ]

    /// Score a time-ordered or unordered HR series. Each adjacent interval uses
    /// the earlier sample's intensity; gaps over 90 seconds contribute no load.
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              mode: Mode) -> Double? {
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
        guard effectiveMax.isFinite, restingHR.isFinite, effectiveMax > restingHR else { return nil }

        let sorted = hr
            .filter { (30...240).contains($0.bpm) }
            .sorted { lhs, rhs in lhs.ts == rhs.ts ? lhs.bpm < rhs.bpm : lhs.ts < rhs.ts }

        let reserve = effectiveMax - restingHR
        var cardiovascularLoad = 0.0
        var coverageSeconds = 0
        if sorted.count >= minReadings {
            for pair in zip(sorted, sorted.dropFirst()) {
                let delta = pair.1.ts - pair.0.ts
                guard delta > 0, delta <= maxIntervalSeconds else { continue }
                coverageSeconds += delta
                let hrr = min(100, max(0, (Double(pair.0.bpm) - restingHR) / reserve * 100))
                cardiovascularLoad += loadPerMinute(atHRR: hrr) * Double(delta) / 60.0
            }
        }
        let hasCardiovascularCoverage = coverageSeconds >= minCoverageSeconds

        switch mode {
        case .activity:
            guard hasCardiovascularCoverage else { return nil }
            return storedValue(fromDisplay: displayStrain(forEffectiveLoad: cardiovascularLoad))
        case .physiologicalDay(let context):
            guard context.hasWearCoverage else { return nil }
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
