import XCTest
@testable import StrandAnalytics

/// Pins the iPhone-side recovery estimate for sparse daily HealthKit aggregates. This is package logic, not a
/// watchOS target: at-baseline inputs land near mid recovery, strong positive/negative deviations move the
/// score, and insufficient evidence remains nil/calibrating.
final class AggregateRecoveryTests: XCTestCase {
    func testAtBaselineGivesMidRecoverySolid() {
        let history = Array(repeating: 45.0, count: 14)
        let rhrHistory = Array(repeating: 52.0, count: 14)
        let result = WatchRecovery.compute(
            todaySDNN: 45,
            todayRHR: 52,
            sdnnHistory: history,
            rhrHistory: rhrHistory
        )
        XCTAssertNotNil(result.recovery)
        XCTAssertGreaterThanOrEqual(result.recovery!, 40)
        XCTAssertLessThanOrEqual(result.recovery!, 60)
        XCTAssertEqual(result.confidence, .solid)
    }

    func testPositiveAndNegativeDeviationMoveScore() {
        let history = Array(repeating: 45.0, count: 14)
        let rhrHistory = Array(repeating: 52.0, count: 14)
        let positive = WatchRecovery.compute(
            todaySDNN: 70,
            todayRHR: 46,
            sdnnHistory: history,
            rhrHistory: rhrHistory
        )
        let negative = WatchRecovery.compute(
            todaySDNN: 22,
            todayRHR: 62,
            sdnnHistory: history,
            rhrHistory: rhrHistory
        )
        XCTAssertGreaterThan(positive.recovery ?? 0, 65)
        XCTAssertLessThan(negative.recovery ?? 100, 40)
    }

    func testInsufficientOrMissingHRVCalibrates() {
        let thin = WatchRecovery.compute(
            todaySDNN: 45,
            todayRHR: 52,
            sdnnHistory: [45, 46],
            rhrHistory: [52, 51]
        )
        let missing = WatchRecovery.compute(
            todaySDNN: nil,
            todayRHR: 52,
            sdnnHistory: Array(repeating: 45, count: 14),
            rhrHistory: Array(repeating: 52, count: 14)
        )
        XCTAssertNil(thin.recovery)
        XCTAssertEqual(thin.confidence, .calibrating)
        XCTAssertNil(missing.recovery)
        XCTAssertEqual(missing.confidence, .calibrating)
    }

    func testExactMinimumHistoryScores() {
        let count = WatchRecovery.minBaselineNights
        let result = WatchRecovery.compute(
            todaySDNN: 45,
            todayRHR: 52,
            sdnnHistory: Array(repeating: 45, count: count),
            rhrHistory: Array(repeating: 52, count: count)
        )
        XCTAssertNotNil(result.recovery)
        XCTAssertNotEqual(result.confidence, .calibrating)
    }

    func testMissingRHRStillScoresFromHRV() {
        let result = WatchRecovery.compute(
            todaySDNN: 45,
            todayRHR: nil,
            sdnnHistory: Array(repeating: 45, count: 14),
            rhrHistory: Array(repeating: 52, count: 14)
        )
        XCTAssertNotNil(result.recovery)
    }

    func testMatchesSharedRecoveryScale() {
        let history = Array(repeating: 45.0, count: 14)
        let rhrHistory = Array(repeating: 52.0, count: 14)
        let result = WatchRecovery.compute(
            todaySDNN: 58,
            todayRHR: 50,
            sdnnHistory: history,
            rhrHistory: rhrHistory
        )
        let hrvBaseline = Baselines.foldHistory(history.map(Optional.init), cfg: Baselines.hrvCfg)
        let rhrBaseline = Baselines.foldHistory(rhrHistory.map(Optional.init), cfg: Baselines.restingHRCfg)
        let shared = RecoveryScorer.recovery(
            hrv: 58,
            rhr: 50,
            resp: nil,
            hrvBaseline: hrvBaseline,
            rhrBaseline: rhrBaseline,
            respBaseline: nil,
            sleepPerf: nil
        )
        XCTAssertEqual(result.recovery!, shared!, accuracy: 0.0001)
    }
}
