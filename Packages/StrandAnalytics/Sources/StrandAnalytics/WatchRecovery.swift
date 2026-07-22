import Foundation

/// Recovery/Charge from sparse daily Apple Health aggregates.
///
/// This lives in the iPhone analytics package; it is not a watchOS target. The computation is also reused
/// for other aggregate-only wearable imports. It preserves the existing score semantics and keeps recovery
/// nil until a usable personal baseline exists.
public enum WatchRecovery {
    public struct Result: Equatable, Sendable {
        public let recovery: Double?
        public let confidence: ScoreConfidence

        public init(recovery: Double?, confidence: ScoreConfidence) {
            self.recovery = recovery
            self.confidence = confidence
        }
    }

    public static let minBaselineNights = 7

    public static func compute(
        todaySDNN: Double?,
        todayRHR: Int?,
        sdnnHistory: [Double],
        rhrHistory: [Double]
    ) -> Result {
        let hrvBase = Baselines.foldHistory(sdnnHistory.map(Optional.init), cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHistory.map(Optional.init), cfg: Baselines.restingHRCfg)
        let confidence = ScoreConfidence.charge(recovery: todaySDNN, hrvBaseline: hrvBase)

        guard let sdnn = todaySDNN,
              hrvBase.usable,
              sdnnHistory.count >= minBaselineNights else {
            return Result(recovery: nil, confidence: .calibrating)
        }

        let recovery = RecoveryScorer.recovery(
            hrv: sdnn,
            rhr: todayRHR.map(Double.init) ?? rhrBase.baseline,
            resp: nil,
            hrvBaseline: hrvBase,
            rhrBaseline: todayRHR != nil ? rhrBase : nil,
            respBaseline: nil,
            sleepPerf: nil
        )
        guard let recovery else {
            return Result(recovery: nil, confidence: .calibrating)
        }
        return Result(recovery: recovery, confidence: confidence)
    }
}
