import XCTest
@testable import StrandAnalytics

/// N2-3: Charge baselines as of the day before (AN-01) and an exit from the hard-outlier gate after a
/// lasting shift (AN-04).
final class BaselineAsOfAndRegimeShiftTests: XCTestCase {

    private let cfg = Baselines.hrvCfg

    private func key(_ i: Int) -> String {
        let base = Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 1, day: 1))!
        let date = base.addingTimeInterval(TimeInterval(i * 86_400))
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func settled(_ n: Int = 20) -> BaselineState {
        var state: BaselineState?
        for i in 0..<n { state = Baselines.update(state, value: [58.0, 60.0, 62.0][i % 3], cfg: cfg) }
        return state!
    }

    // MARK: - AN-04

    /// A lasting shift (60 → 100 ms) is rejected for K−1 nights while the status reads provisional, then
    /// folded, and the baseline is within 2σ of the new level by night K+7.
    func testSustainedStepChangeConvergesWithinKPlus7Nights() {
        let start = settled()
        XCTAssertEqual(start.status, .trusted)
        let k = Baselines.regimeShiftNights
        var state = start
        for night in 1...(k + 7) {
            let before = state
            state = Baselines.update(state, value: 100, cfg: cfg)
            if night < k {
                XCTAssertEqual(state.baseline, start.baseline, "night \(night) is still rejected")
                XCTAssertEqual(state.rejectStreak, night)
                XCTAssertEqual(state.status, .provisional, "an open streak is not reported as trusted")
            } else {
                XCTAssertGreaterThan(state.baseline, before.baseline, "night \(night) is folded")
                XCTAssertEqual(state.rejectStreak, 0)
                XCTAssertTrue(state.usable)
            }
        }
        let z = (100 - state.baseline) / (1.253 * state.spread)
        XCTAssertLessThan(abs(z), 2, "converged within K+7 nights: baseline \(state.baseline)")
        XCTAssertEqual(state.status, .provisional, "the restarted baseline relearns before it is trusted again")
    }

    /// A one-off outlier is still rejected, and the next normal night clears the streak.
    func testOneOffOutlierIsStillRejected() {
        let start = settled()
        let outlier = Baselines.update(start, value: 100, cfg: cfg)
        XCTAssertEqual(outlier.baseline, start.baseline)
        XCTAssertEqual(outlier.rejectStreak, 1)
        let back = Baselines.update(outlier, value: 60, cfg: cfg)
        XCTAssertEqual(back.rejectStreak, 0)
        XCTAssertEqual(back.status, .trusted)
        XCTAssertEqual(back.baseline, start.baseline, accuracy: 1)
    }

    /// Outliers on alternating sides are noise, not a shift: the streak restarts with each side change.
    func testAlternatingOutliersNeverRestartTheBaseline() {
        var state = settled()
        let start = state
        for value in [100.0, 20.0, 100.0, 20.0, 100.0] {
            state = Baselines.update(state, value: value, cfg: cfg)
            XCTAssertEqual(state.rejectStreak, 1)
        }
        XCTAssertEqual(state.baseline, start.baseline)
        XCTAssertEqual(state.nValid, start.nValid)
    }

    /// A missing night neither extends nor breaks an open streak.
    func testMissingNightKeepsTheStreak() {
        var state = Baselines.update(settled(), value: 100, cfg: cfg)
        state = Baselines.update(state, value: nil, cfg: cfg)
        XCTAssertEqual(state.rejectStreak, 1)
        XCTAssertEqual(state.status, .provisional)
        state = Baselines.update(state, value: 100, cfg: cfg)
        XCTAssertEqual(state.rejectStreak, 2)
    }

    // MARK: - AN-01

    /// asOf(D) is the fold of the nights strictly before D, and it ignores D's own night.
    func testAsOfIsTheFoldOfEarlierNightsOnly() {
        let values: [Double?] = (0..<30).map { (i: Int) -> Double? in
            i % 7 == 3 ? nil : 50.0 + Double(i % 5) * 3.0
        }
        let keys = (0..<30).map(key)
        let timeline = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
        for d in [0, 1, 5, 17, 29] {
            let expected = Baselines.foldHistory(Array(values[..<d]), dayKeys: Array(keys[..<d]), cfg: cfg,
                                                 baselineEpoch: 0)
            XCTAssertEqual(timeline.asOf(keys[d]), expected, "day \(d)")
        }
        XCTAssertEqual(timeline.latest, Baselines.foldHistory(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0))
        // A day after the last folded night sees every night.
        XCTAssertEqual(timeline.asOf(key(31)), timeline.latest)
    }

    /// A past day's Charge does not change when later nights arrive, however extreme they are.
    func testPastDayChargeDoesNotChangeWhenLaterNightsArrive() throws {
        let hrv: [Double?] = (0..<20).map { (i: Int) -> Double? in 55.0 + Double(i % 4) * 2.0 }
        let rhr: [Double?] = (0..<20).map { (i: Int) -> Double? in 52.0 + Double(i % 3) }
        let keys = (0..<20).map(key)
        func charge(day: Int, hrvHistory: [Double?], rhrHistory: [Double?], keys: [String]) -> Double? {
            let h = Baselines.foldHistoryAsOf(hrvHistory, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
            let r = Baselines.foldHistoryAsOf(rhrHistory, dayKeys: keys, cfg: Baselines.restingHRCfg,
                                              baselineEpoch: 0)
            return RecoveryScorer.recovery(hrv: 62, rhr: 51, resp: nil, hrvBaseline: h.asOf(keys[day]),
                                           rhrBaseline: r.asOf(keys[day]), respBaseline: nil, sleepPerf: 0.8)
        }
        let before = try XCTUnwrap(charge(day: 15, hrvHistory: hrv, rhrHistory: rhr, keys: keys))
        let laterKeys = keys + (20..<30).map(key)
        let after = try XCTUnwrap(charge(day: 15, hrvHistory: hrv + Array(repeating: 140, count: 10),
                                         rhrHistory: rhr + Array(repeating: 80, count: 10), keys: laterKeys))
        XCTAssertEqual(before, after)
    }

    /// The recalibration epoch drops earlier nights exactly as `foldHistory` does.
    func testAsOfHonoursTheRecalibrationEpoch() throws {
        let values: [Double?] = Array(repeating: 60, count: 12)
        let keys = (0..<12).map(key)
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        let epoch = try XCTUnwrap(f.date(from: key(8))).timeIntervalSince1970
        let timeline = Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: cfg, baselineEpoch: epoch)
        XCTAssertEqual(timeline.asOf(key(8)).nValid, 0)
        XCTAssertEqual(timeline.asOf(key(11)).nValid, 3)
        XCTAssertEqual(timeline.latest, Baselines.foldHistory(values, dayKeys: keys, cfg: cfg, baselineEpoch: epoch))
    }
}
