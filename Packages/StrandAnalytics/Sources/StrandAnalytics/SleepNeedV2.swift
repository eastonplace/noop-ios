import Foundation

/// Versioned, transparent sleep-need model used by Sleep Performance V2.
///
/// The model deliberately does not infer "need" from an unconditional average of
/// actual sleep. A chronically short sleeper therefore cannot teach the engine that
/// chronic restriction is sufficient. Automatic personalization is upward-only from
/// the default baseline; an explicit user override may move the baseline either way.
public enum SleepNeedV2 {
    public static let modelVersion = "sleep-need-v2.0"

    public enum BaselineSource: String, Codable, Equatable, Sendable {
        case defaultPopulation
        case learnedUpward
        case userOverride
    }

    public struct Config: Equatable, Sendable {
        public var defaultBaselineMinutes: Double
        public var minBaselineMinutes: Double
        public var maxBaselineMinutes: Double
        public var minimumEligibleBaselineNights: Int
        public var baselinePercentile: Double
        public var lowEffortCeiling: Double
        public var minimumEfficiencyForBaseline: Double
        public var maximumDebtForBaseline: Double

        public var maximumStrainAdjustmentMinutes: Double
        public var strainMidpointEffort: Double
        public var strainSlope: Double
        public var debtRepaymentRate: Double
        public var maximumDebtRepaymentMinutes: Double
        public var napCreditRate: Double
        public var maximumNapCreditMinutes: Double
        public var minimumNeedMinutes: Double
        public var maximumNeedMinutes: Double
        public var maximumDebtBalanceMinutes: Double

        public init(
            defaultBaselineMinutes: Double = 480,
            minBaselineMinutes: Double = 420,
            maxBaselineMinutes: Double = 570,
            minimumEligibleBaselineNights: Int = 7,
            baselinePercentile: Double = 0.75,
            lowEffortCeiling: Double = 35,
            minimumEfficiencyForBaseline: Double = 0.85,
            maximumDebtForBaseline: Double = 30,
            maximumStrainAdjustmentMinutes: Double = 60,
            strainMidpointEffort: Double = 62,
            strainSlope: Double = 11.5,
            debtRepaymentRate: Double = 0.25,
            maximumDebtRepaymentMinutes: Double = 90,
            napCreditRate: Double = 0.80,
            maximumNapCreditMinutes: Double = 90,
            minimumNeedMinutes: Double = 390,
            maximumNeedMinutes: Double = 630,
            maximumDebtBalanceMinutes: Double = 300
        ) {
            self.defaultBaselineMinutes = defaultBaselineMinutes
            self.minBaselineMinutes = minBaselineMinutes
            self.maxBaselineMinutes = maxBaselineMinutes
            self.minimumEligibleBaselineNights = minimumEligibleBaselineNights
            self.baselinePercentile = baselinePercentile
            self.lowEffortCeiling = lowEffortCeiling
            self.minimumEfficiencyForBaseline = minimumEfficiencyForBaseline
            self.maximumDebtForBaseline = maximumDebtForBaseline
            self.maximumStrainAdjustmentMinutes = maximumStrainAdjustmentMinutes
            self.strainMidpointEffort = strainMidpointEffort
            self.strainSlope = strainSlope
            self.debtRepaymentRate = debtRepaymentRate
            self.maximumDebtRepaymentMinutes = maximumDebtRepaymentMinutes
            self.napCreditRate = napCreditRate
            self.maximumNapCreditMinutes = maximumNapCreditMinutes
            self.minimumNeedMinutes = minimumNeedMinutes
            self.maximumNeedMinutes = maximumNeedMinutes
            self.maximumDebtBalanceMinutes = maximumDebtBalanceMinutes
        }

        public static let production = Config()
    }

    /// One prior night eligible to inform the personal baseline. The caller must
    /// provide only values known before the night being scored to avoid future leakage.
    public struct BaselineNight: Equatable, Sendable {
        public let totalSleepMinutes: Double
        public let previousDayEffort: Double?
        public let efficiency: Double?
        public let debtBeforeNightMinutes: Double?

        public init(totalSleepMinutes: Double,
                    previousDayEffort: Double?,
                    efficiency: Double?,
                    debtBeforeNightMinutes: Double?) {
            self.totalSleepMinutes = totalSleepMinutes
            self.previousDayEffort = previousDayEffort
            self.efficiency = efficiency
            self.debtBeforeNightMinutes = debtBeforeNightMinutes
        }
    }

    public struct BaselineEstimate: Codable, Equatable, Sendable {
        public let minutes: Double
        public let source: BaselineSource
        public let eligibleNightCount: Int
        public let modelVersion: String

        public init(minutes: Double,
                    source: BaselineSource,
                    eligibleNightCount: Int,
                    modelVersion: String = SleepNeedV2.modelVersion) {
            self.minutes = minutes
            self.source = source
            self.eligibleNightCount = eligibleNightCount
            self.modelVersion = modelVersion
        }
    }

    public struct Inputs: Equatable, Sendable {
        public let baseline: BaselineEstimate
        /// Previous calendar day's NOOP Effort on its stored 0...100 scale.
        public let previousDayEffort: Double?
        /// Positive rolling debt balance. Negative sleep credit is never accepted.
        public let sleepDebtMinutes: Double
        /// Naps since the preceding main sleep, before the main sleep being planned.
        public let recentNapMinutes: Double

        public init(baseline: BaselineEstimate,
                    previousDayEffort: Double?,
                    sleepDebtMinutes: Double,
                    recentNapMinutes: Double) {
            self.baseline = baseline
            self.previousDayEffort = previousDayEffort
            self.sleepDebtMinutes = sleepDebtMinutes
            self.recentNapMinutes = recentNapMinutes
        }
    }

    public struct Breakdown: Codable, Equatable, Sendable {
        public let baselineMinutes: Double
        public let baselineSource: BaselineSource
        public let strainAdjustmentMinutes: Double
        public let napCreditMinutes: Double
        /// Need before debt repayment is added, after the global physiological bounds.
        public let coreRequirementMinutes: Double
        /// Portion of the current debt explicitly scheduled for repayment tonight.
        public let debtRepaymentMinutes: Double
        public let totalMinutes: Double
        public let debtBalanceBeforeNightMinutes: Double
        public let modelVersion: String

        public init(baselineMinutes: Double,
                    baselineSource: BaselineSource,
                    strainAdjustmentMinutes: Double,
                    napCreditMinutes: Double,
                    coreRequirementMinutes: Double,
                    debtRepaymentMinutes: Double,
                    totalMinutes: Double,
                    debtBalanceBeforeNightMinutes: Double,
                    modelVersion: String = SleepNeedV2.modelVersion) {
            self.baselineMinutes = baselineMinutes
            self.baselineSource = baselineSource
            self.strainAdjustmentMinutes = strainAdjustmentMinutes
            self.napCreditMinutes = napCreditMinutes
            self.coreRequirementMinutes = coreRequirementMinutes
            self.debtRepaymentMinutes = debtRepaymentMinutes
            self.totalMinutes = totalMinutes
            self.debtBalanceBeforeNightMinutes = debtBalanceBeforeNightMinutes
            self.modelVersion = modelVersion
        }
    }

    public enum DebtUpdateReason: String, Codable, Equatable, Sendable {
        case scoredNight
        case heldMissingSleep
    }

    public struct DebtUpdate: Codable, Equatable, Sendable {
        public let previousBalanceMinutes: Double
        public let addedDeficitMinutes: Double
        public let repaidMinutes: Double
        public let newBalanceMinutes: Double
        public let reason: DebtUpdateReason
        public let modelVersion: String

        public init(previousBalanceMinutes: Double,
                    addedDeficitMinutes: Double,
                    repaidMinutes: Double,
                    newBalanceMinutes: Double,
                    reason: DebtUpdateReason,
                    modelVersion: String = SleepNeedV2.modelVersion) {
            self.previousBalanceMinutes = previousBalanceMinutes
            self.addedDeficitMinutes = addedDeficitMinutes
            self.repaidMinutes = repaidMinutes
            self.newBalanceMinutes = newBalanceMinutes
            self.reason = reason
            self.modelVersion = modelVersion
        }
    }

    /// Estimate a personal baseline without normalizing chronic restriction.
    ///
    /// - An explicit override wins and is clamped to the supported range.
    /// - Automatic learning uses the configured upper percentile of low-effort,
    ///   low-debt, efficient nights.
    /// - Automatic learning may raise the default but never lower it.
    public static func estimateBaseline(
        history: [BaselineNight],
        userOverrideMinutes: Double? = nil,
        config: Config = .production
    ) -> BaselineEstimate {
        if let override = userOverrideMinutes, override.isFinite {
            return BaselineEstimate(
                minutes: clamp(override, config.minBaselineMinutes, config.maxBaselineMinutes),
                source: .userOverride,
                eligibleNightCount: 0)
        }

        let eligible = history.compactMap { night -> Double? in
            guard night.totalSleepMinutes.isFinite,
                  night.totalSleepMinutes >= 240,
                  night.totalSleepMinutes <= 720,
                  let effort = night.previousDayEffort, effort.isFinite,
                  effort <= config.lowEffortCeiling,
                  let efficiency = night.efficiency, efficiency.isFinite,
                  efficiency >= config.minimumEfficiencyForBaseline,
                  let debt = night.debtBeforeNightMinutes, debt.isFinite,
                  debt <= config.maximumDebtForBaseline
            else { return nil }
            return night.totalSleepMinutes
        }

        guard eligible.count >= max(1, config.minimumEligibleBaselineNights) else {
            return BaselineEstimate(
                minutes: clamp(config.defaultBaselineMinutes,
                               config.minBaselineMinutes,
                               config.maxBaselineMinutes),
                source: .defaultPopulation,
                eligibleNightCount: eligible.count)
        }

        let learned = percentile(eligible, p: config.baselinePercentile)
        let upwardOnly = max(config.defaultBaselineMinutes, learned)
        return BaselineEstimate(
            minutes: clamp(upwardOnly, config.minBaselineMinutes, config.maxBaselineMinutes),
            source: .learnedUpward,
            eligibleNightCount: eligible.count)
    }

    /// Calculate tonight's dynamic need:
    /// baseline + previous-day strain + bounded debt repayment - nap credit.
    public static func calculate(_ inputs: Inputs,
                                 config: Config = .production) -> Breakdown {
        let baseline = clamp(inputs.baseline.minutes,
                             config.minBaselineMinutes,
                             config.maxBaselineMinutes)
        let strain = strainAdjustment(previousDayEffort: inputs.previousDayEffort,
                                      config: config)
        let nap = min(max(0, finiteOrZero(inputs.recentNapMinutes)) * config.napCreditRate,
                      max(0, config.maximumNapCreditMinutes))
        let debtBalance = clamp(finiteOrZero(inputs.sleepDebtMinutes),
                                0,
                                max(0, config.maximumDebtBalanceMinutes))

        let rawCore = baseline + strain - nap
        let core = clamp(rawCore, config.minimumNeedMinutes, config.maximumNeedMinutes)
        let requestedDebtRepayment = min(debtBalance * max(0, config.debtRepaymentRate),
                                         max(0, config.maximumDebtRepaymentMinutes))
        let total = clamp(core + requestedDebtRepayment,
                          config.minimumNeedMinutes,
                          config.maximumNeedMinutes)
        let effectiveDebtRepayment = max(0, total - core)

        return Breakdown(
            baselineMinutes: round2(baseline),
            baselineSource: inputs.baseline.source,
            strainAdjustmentMinutes: round2(strain),
            napCreditMinutes: round2(nap),
            coreRequirementMinutes: round2(core),
            debtRepaymentMinutes: round2(effectiveDebtRepayment),
            totalMinutes: round2(total),
            debtBalanceBeforeNightMinutes: round2(debtBalance))
    }

    /// Advance the positive rolling debt balance after a main sleep.
    ///
    /// Meeting the core requirement holds debt steady. Sleep above the core requirement
    /// repays existing debt minute-for-minute, bounded per night. Sleep below the core
    /// requirement adds the uncovered deficit. Missing sleep data holds the prior balance.
    public static func updateDebt(
        previousBalanceMinutes: Double,
        need: Breakdown,
        mainSleepMinutes: Double?,
        config: Config = .production
    ) -> DebtUpdate {
        let previous = clamp(finiteOrZero(previousBalanceMinutes),
                             0,
                             max(0, config.maximumDebtBalanceMinutes))
        guard let mainSleepMinutes,
              mainSleepMinutes.isFinite,
              mainSleepMinutes > 0 else {
            return DebtUpdate(previousBalanceMinutes: round2(previous),
                              addedDeficitMinutes: 0,
                              repaidMinutes: 0,
                              newBalanceMinutes: round2(previous),
                              reason: .heldMissingSleep)
        }

        let slept = max(0, mainSleepMinutes)
        let deficit = max(0, need.coreRequirementMinutes - slept)
        let repaymentCapacity = max(0, slept - need.coreRequirementMinutes)
        let repaid = min(previous,
                         min(repaymentCapacity,
                             max(0, config.maximumDebtRepaymentMinutes)))
        let next = clamp(previous + deficit - repaid,
                         0,
                         max(0, config.maximumDebtBalanceMinutes))

        return DebtUpdate(previousBalanceMinutes: round2(previous),
                          addedDeficitMinutes: round2(deficit),
                          repaidMinutes: round2(repaid),
                          newBalanceMinutes: round2(next),
                          reason: .scoredNight)
    }

    /// Monotonic 0...max adjustment from NOOP Effort 0...100. The normalization
    /// pins effort 0 to exactly 0 minutes and effort 100 to exactly the configured max.
    public static func strainAdjustment(previousDayEffort: Double?,
                                        config: Config = .production) -> Double {
        guard let previousDayEffort, previousDayEffort.isFinite else { return 0 }
        let effort = clamp(previousDayEffort, 0, 100)
        let slope = max(abs(config.strainSlope), 0.0001)
        func sigmoid(_ x: Double) -> Double {
            1.0 / (1.0 + exp(-(x - config.strainMidpointEffort) / slope))
        }
        let lo = sigmoid(0)
        let hi = sigmoid(100)
        guard hi > lo else { return 0 }
        let normalized = clamp((sigmoid(effort) - lo) / (hi - lo), 0, 1)
        return max(0, config.maximumStrainAdjustmentMinutes) * normalized
    }

    private static func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let q = clamp(p, 0, 1) * Double(sorted.count - 1)
        let lo = Int(floor(q))
        let hi = Int(ceil(q))
        if lo == hi { return sorted[lo] }
        let fraction = q - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * fraction
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        let lo = min(lower, upper)
        let hi = max(lower, upper)
        return min(max(value, lo), hi)
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
