import Foundation

/// Transparent Sleep Performance V2.
///
/// The headline is intentionally sufficiency-led and uses a weighted geometric
/// mean, so excellent secondary signals cannot fully conceal a short night.
/// Deep/REM staging remains a diagnostic detail and is not an input to the score.
public enum SleepPerformanceV2 {
    public static let modelVersion = "sleep-performance-v2.0"

    public struct Config: Equatable, Sendable {
        public var sufficiencyWeight: Double
        public var efficiencyWeight: Double
        public var consistencyWeight: Double
        public var lowStressWeight: Double
        public var consistencyHistoryNights: Int
        public var consistencyToleranceMinutes: Double

        public init(sufficiencyWeight: Double = 0.70,
                    efficiencyWeight: Double = 0.10,
                    consistencyWeight: Double = 0.10,
                    lowStressWeight: Double = 0.10,
                    consistencyHistoryNights: Int = 4,
                    consistencyToleranceMinutes: Double = 90) {
            self.sufficiencyWeight = sufficiencyWeight
            self.efficiencyWeight = efficiencyWeight
            self.consistencyWeight = consistencyWeight
            self.lowStressWeight = lowStressWeight
            self.consistencyHistoryNights = consistencyHistoryNights
            self.consistencyToleranceMinutes = consistencyToleranceMinutes
        }

        public static let production = Config()
    }

    public struct SleepTiming: Codable, Equatable, Sendable {
        /// Minute of local day, normalized onto 0...1439 by the engine.
        public let onsetMinute: Int
        /// Minute of local day, normalized onto 0...1439 by the engine.
        public let wakeMinute: Int

        public init(onsetMinute: Int, wakeMinute: Int) {
            self.onsetMinute = onsetMinute
            self.wakeMinute = wakeMinute
        }
    }

    public struct Inputs: Equatable, Sendable {
        public let mainSleepMinutes: Double
        public let need: SleepNeedV2.Breakdown
        /// Asleep / in-bed in 0...1. Required because a recorded window without
        /// a usable asleep estimate is not enough to score honestly.
        public let efficiency: Double?
        /// Sleep/wake regularity in 0...1. nil means the history is not calibrated.
        public let consistency: Double?
        /// Low overnight physiological stress in 0...1. nil means the upstream
        /// stress signal is unavailable; no neutral points are invented.
        public let lowStressQuality: Double?

        public init(mainSleepMinutes: Double,
                    need: SleepNeedV2.Breakdown,
                    efficiency: Double?,
                    consistency: Double?,
                    lowStressQuality: Double?) {
            self.mainSleepMinutes = mainSleepMinutes
            self.need = need
            self.efficiency = efficiency
            self.consistency = consistency
            self.lowStressQuality = lowStressQuality
        }
    }

    public struct Components: Codable, Equatable, Sendable {
        public let sufficiency: Double
        public let efficiency: Double
        public let consistency: Double?
        public let lowStressQuality: Double?

        public init(sufficiency: Double,
                    efficiency: Double,
                    consistency: Double?,
                    lowStressQuality: Double?) {
            self.sufficiency = sufficiency
            self.efficiency = efficiency
            self.consistency = consistency
            self.lowStressQuality = lowStressQuality
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let score: Double
        public let components: Components
        /// Sum of configured component weights backed by real inputs, in 0...1.
        public let inputCoverage: Double
        public let confidence: ScoreConfidence
        public let need: SleepNeedV2.Breakdown
        public let modelVersion: String

        public init(score: Double,
                    components: Components,
                    inputCoverage: Double,
                    confidence: ScoreConfidence,
                    need: SleepNeedV2.Breakdown,
                    modelVersion: String = SleepPerformanceV2.modelVersion) {
            self.score = score
            self.components = components
            self.inputCoverage = inputCoverage
            self.confidence = confidence
            self.need = need
            self.modelVersion = modelVersion
        }

        /// Exact normalized value RecoveryScorer should consume for its sleep term.
        public var recoveryInput: Double { score / 100.0 }
    }

    /// Score one main sleep. Returns nil when total sleep, dynamic need, or
    /// efficiency is unavailable. Optional consistency/stress inputs are omitted,
    /// never replaced with free neutral points; the result is capped by input
    /// coverage (90 with one optional component missing, 80 with both missing).
    public static func score(_ inputs: Inputs,
                             config: Config = .production) -> Result? {
        guard inputs.mainSleepMinutes.isFinite,
              inputs.mainSleepMinutes > 0,
              inputs.need.totalMinutes.isFinite,
              inputs.need.totalMinutes > 0,
              let rawEfficiency = inputs.efficiency,
              rawEfficiency.isFinite else { return nil }

        let sufficiency = clamp01(inputs.mainSleepMinutes / inputs.need.totalMinutes)
        let efficiency = clamp01(rawEfficiency)
        let consistency = inputs.consistency.flatMap { $0.isFinite ? clamp01($0) : nil }
        let lowStress = inputs.lowStressQuality.flatMap { $0.isFinite ? clamp01($0) : nil }

        let weights = normalizedWeights(config)
        var terms: [(value: Double, weight: Double)] = [
            (sufficiency, weights.sufficiency),
            (efficiency, weights.efficiency),
        ]
        if let consistency { terms.append((consistency, weights.consistency)) }
        if let lowStress { terms.append((lowStress, weights.lowStress)) }

        let coverage = terms.reduce(0.0) { $0 + $1.weight }
        guard coverage > 0 else { return nil }

        let hasZero = terms.contains { $0.value <= 0 }
        let geometric: Double
        if hasZero {
            geometric = 0
        } else {
            let logSum = terms.reduce(0.0) { partial, term in
                partial + term.weight * log(term.value)
            }
            geometric = exp(logSum / coverage)
        }

        // Coverage is a hard honesty ceiling. Missing consistency or stress cannot
        // make an otherwise strong night look fully measured.
        let score01 = min(clamp01(geometric), clamp01(coverage))
        let confidence: ScoreConfidence
        if coverage >= 0.999_999 {
            confidence = .solid
        } else if coverage >= 0.899_999 {
            confidence = .building
        } else {
            confidence = .calibrating
        }

        return Result(
            score: round2(score01 * 100),
            components: Components(sufficiency: round4(sufficiency),
                                   efficiency: round4(efficiency),
                                   consistency: consistency.map(round4),
                                   lowStressQuality: lowStress.map(round4)),
            inputCoverage: round4(coverage),
            confidence: confidence,
            need: inputs.need)
    }

    /// Consistency for the current night against the immediately preceding local
    /// nights. Uses circular clock math, so 23:50 and 00:10 are 20 minutes apart.
    /// Returns nil until the configured number of prior nights is available.
    public static func consistency(current: SleepTiming,
                                   priorNights: [SleepTiming],
                                   config: Config = .production) -> Double? {
        let required = max(1, config.consistencyHistoryNights)
        guard priorNights.count >= required else { return nil }
        let history = Array(priorNights.suffix(required))
        let onsetTarget = circularMeanMinute(history.map(\.onsetMinute))
        let wakeTarget = circularMeanMinute(history.map(\.wakeMinute))
        let onsetDelta = circularDistanceMinutes(current.onsetMinute, onsetTarget)
        let wakeDelta = circularDistanceMinutes(current.wakeMinute, wakeTarget)
        let rms = ((onsetDelta * onsetDelta + wakeDelta * wakeDelta) / 2).squareRoot()
        let tolerance = max(1, config.consistencyToleranceMinutes)
        return round4(exp(-0.5 * pow(rms / tolerance, 2)))
    }

    private static func normalizedWeights(_ config: Config)
        -> (sufficiency: Double, efficiency: Double, consistency: Double, lowStress: Double) {
        let raw = [max(0, config.sufficiencyWeight),
                   max(0, config.efficiencyWeight),
                   max(0, config.consistencyWeight),
                   max(0, config.lowStressWeight)]
        let sum = raw.reduce(0, +)
        guard sum > 0 else { return (0.70, 0.10, 0.10, 0.10) }
        return (raw[0] / sum, raw[1] / sum, raw[2] / sum, raw[3] / sum)
    }

    private static func circularMeanMinute(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        let day = 1440.0
        var sinSum = 0.0
        var cosSum = 0.0
        for value in values {
            let angle = 2 * Double.pi * normalizeMinute(value) / day
            sinSum += sin(angle)
            cosSum += cos(angle)
        }
        var angle = atan2(sinSum / Double(values.count), cosSum / Double(values.count))
        if angle < 0 { angle += 2 * Double.pi }
        return angle * day / (2 * Double.pi)
    }

    private static func circularDistanceMinutes(_ lhs: Int, _ rhs: Double) -> Double {
        let day = 1440.0
        let a = normalizeMinute(lhs)
        let b = rhs.truncatingRemainder(dividingBy: day)
        let direct = abs(a - (b < 0 ? b + day : b))
        return min(direct, day - direct)
    }

    private static func normalizeMinute(_ value: Int) -> Double {
        let day = 1440
        return Double(((value % day) + day) % day)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}
