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
        compute(todaySDNN: todaySDNN, todayRHR: todayRHR,
                hrvBase: Baselines.foldHistory(sdnnHistory.map(Optional.init), cfg: Baselines.hrvCfg),
                rhrBase: Baselines.foldHistory(rhrHistory.map(Optional.init), cfg: Baselines.restingHRCfg),
                sdnnHistoryCount: sdnnHistory.count)
    }

    /// One aggregate day of an import-only history.
    public struct Day: Sendable {
        public let day: String      // yyyy-MM-dd
        public let sdnn: Double?
        public let rhr: Int?

        public init(day: String, sdnn: Double?, rhr: Int?) {
            self.day = day; self.sdnn = sdnn; self.rhr = rhr
        }
    }

    /// Scores every day against the days before it in ONE pass (DL-12): the running SDNN and resting-HR
    /// baselines are updated after each day is scored, instead of re-folding the whole prior history per
    /// day (quadratic over years of Apple Health). Same result as `compute` with the prior non-nil values,
    /// except that the manual recalibration epochs are now honoured: days before `hrvEpoch` /
    /// `recoveryEpoch` (epoch seconds; 0 = none) don't feed the SDNN / resting-HR baseline.
    public static func scoreHistory(_ days: [Day], hrvEpoch: Double = 0,
                                    recoveryEpoch: Double = 0) -> [(day: String, result: Result)] {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        var hrvBase = Baselines.foldHistory([], cfg: Baselines.hrvCfg)
        var rhrBase = Baselines.foldHistory([], cfg: Baselines.restingHRCfg)
        var hrvState: BaselineState?
        var rhrState: BaselineState?
        var sdnnCount = 0
        var out: [(day: String, result: Result)] = []
        out.reserveCapacity(days.count)
        for item in days.sorted(by: { $0.day < $1.day }) {
            out.append((item.day, compute(todaySDNN: item.sdnn, todayRHR: item.rhr, hrvBase: hrvBase,
                                          rhrBase: rhrBase, sdnnHistoryCount: sdnnCount)))
            let dayStart = fmt.date(from: item.day)?.timeIntervalSince1970
            if let sdnn = item.sdnn, !(hrvEpoch > 0 && (dayStart ?? .infinity) < hrvEpoch) {
                hrvState = Baselines.update(hrvState, value: sdnn, cfg: Baselines.hrvCfg)
                hrvBase = hrvState ?? hrvBase
                sdnnCount += 1
            }
            if let rhr = item.rhr, !(recoveryEpoch > 0 && (dayStart ?? .infinity) < recoveryEpoch) {
                rhrState = Baselines.update(rhrState, value: Double(rhr), cfg: Baselines.restingHRCfg)
                rhrBase = rhrState ?? rhrBase
            }
        }
        return out
    }

    static func compute(todaySDNN: Double?, todayRHR: Int?, hrvBase: BaselineState, rhrBase: BaselineState,
                        sdnnHistoryCount: Int) -> Result {
        let confidence = ScoreConfidence.charge(recovery: todaySDNN, hrvBaseline: hrvBase)

        guard let sdnn = todaySDNN,
              hrvBase.usable,
              sdnnHistoryCount >= minBaselineNights else {
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
