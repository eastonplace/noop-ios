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
        /// The Charge drivers from the same inputs the score used (review round 4, 3); empty with no score.
        public let drivers: [ChargeDriver]

        public init(recovery: Double?, confidence: ScoreConfidence, drivers: [ChargeDriver] = []) {
            self.recovery = recovery
            self.confidence = confidence
            self.drivers = drivers
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
    /// except that the manual recalibration epochs are now honoured: from the first day on or after
    /// `hrvEpoch` / `recoveryEpoch` (epoch seconds; 0 = none) the SDNN / resting-HR baseline restarts, so
    /// earlier days don't feed it. Days before the epoch keep the baseline of every earlier day, the one
    /// they were scored against, so a rescore can't wipe their Charge (review F1).
    public static func scoreHistory(_ days: [Day], hrvEpoch: Double = 0,
                                    recoveryEpoch: Double = 0) -> [(day: String, result: Result)] {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let emptyHrv = Baselines.foldHistory([], cfg: Baselines.hrvCfg)
        let emptyRhr = Baselines.foldHistory([], cfg: Baselines.restingHRCfg)
        var hrvBase = emptyHrv
        var rhrBase = emptyRhr
        var hrvState: BaselineState?
        var rhrState: BaselineState?
        var sdnnCount = 0
        var hrvRestarted = false
        var rhrRestarted = false
        var out: [(day: String, result: Result)] = []
        out.reserveCapacity(days.count)
        for item in days.sorted(by: { $0.day < $1.day }) {
            let dayStart = fmt.date(from: item.day)?.timeIntervalSince1970 ?? .infinity
            if hrvEpoch > 0, !hrvRestarted, dayStart >= hrvEpoch {
                hrvRestarted = true
                hrvState = nil; hrvBase = emptyHrv; sdnnCount = 0
            }
            if recoveryEpoch > 0, !rhrRestarted, dayStart >= recoveryEpoch {
                rhrRestarted = true
                rhrState = nil; rhrBase = emptyRhr
            }
            out.append((item.day, compute(todaySDNN: item.sdnn, todayRHR: item.rhr, hrvBase: hrvBase,
                                          rhrBase: rhrBase, sdnnHistoryCount: sdnnCount)))
            if let sdnn = item.sdnn {
                hrvState = Baselines.update(hrvState, value: sdnn, cfg: Baselines.hrvCfg)
                hrvBase = hrvState ?? hrvBase
                sdnnCount += 1
            }
            if let rhr = item.rhr {
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

        let rhr = todayRHR.map(Double.init) ?? rhrBase.baseline
        let rhrBaseline = todayRHR != nil ? rhrBase : nil
        let recovery = RecoveryScorer.recovery(
            hrv: sdnn,
            rhr: rhr,
            resp: nil,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBaseline,
            respBaseline: nil,
            sleepPerf: nil
        )
        guard let recovery else {
            return Result(recovery: nil, confidence: .calibrating)
        }
        return Result(recovery: recovery, confidence: confidence,
                      drivers: RecoveryScorer.chargeDrivers(hrv: sdnn, rhr: rhr, resp: nil, hrvBaseline: hrvBase,
                                                            rhrBaseline: rhrBaseline, respBaseline: nil,
                                                            sleepPerf: nil))
    }
}
