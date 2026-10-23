import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ReadinessEngineTests: XCTestCase {

    private func d(_ i: Int, hrv: Double?, rhr: Int?, strain: Double?, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2024-03-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: strain, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    /// 28 baseline days with gentle variation (so SD > 0), then `today` as day 29.
    private func baseline(todayHrv: Double?, todayRhr: Int?, todayStrain: Double?,
                          todayResp: Double? = nil, baseStrain: Double = 10) -> [DailyMetric] {
        var days: [DailyMetric] = []
        for i in 1...28 {
            days.append(d(i, hrv: i % 2 == 0 ? 62 : 58, rhr: i % 2 == 0 ? 54 : 50,
                          strain: baseStrain, resp: i % 2 == 0 ? 14.5 : 13.5))
        }
        days.append(d(29, hrv: todayHrv, rhr: todayRhr, strain: todayStrain, resp: todayResp))
        return days
    }

    func testInsufficientWhenEmpty() {
        XCTAssertEqual(ReadinessEngine.evaluate(days: []).level, .insufficient)
    }

    func testPrimedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below, load steady.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10))
        XCTAssertEqual(r.level, .primed)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.evidence, "72 vs 60 ms")
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.evidence, "46 vs 52 bpm")
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.evidence, "7d 10.0 / 28d 10.0")
    }

    func testWorkloadRatioSignalIsNotNamedTrainingLoad() {
        // The 7-day against 28-day ratio is its own figure; "Training load" is the separate page with its own averages.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10))
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.label, "Workload ratio")
    }

    func testRundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated → two "bad" recovery signals.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(r.level, .rundown)
    }

    func testAcwrSpikeStrains() {
        // Recovery signals neutral, but acute load spikes above chronic.
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: 15)) }
        days.append(d(29, hrv: 60, rhr: 52, strain: 15))
        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .bad)
        XCTAssertEqual(r.level, .strained)
        XCTAssertNotNil(r.acwr)
        XCTAssertGreaterThan(r.acwr!, 1.5)
    }

    // MARK: - AN-09: calendar-indexed load windows

    /// This morning's partial strain (sleep seed + a little load) must not drag the acute mean down.
    func testPartialTodayIsExcludedFromLoadWindows() throws {
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 2))
        XCTAssertEqual(try XCTUnwrap(r.acwr), 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.evidence, "7d 10.0 / 28d 10.0")
    }

    /// Rows after an explicit `today` never enter the windows.
    func testRowsAfterTheTargetDayAreExcluded() throws {
        var days = baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10)
        days.append(d(30, hrv: 60, rhr: 52, strain: 40))
        days.append(d(31, hrv: 60, rhr: 52, strain: 40))
        let r = ReadinessEngine.evaluate(days: days, today: "2024-03-29")
        XCTAssertEqual(try XCTUnwrap(r.acwr), 1.0, accuracy: 1e-9)
    }

    /// Unworn days are gaps in the calendar, not a reason to reach further back: the acute week averages
    /// only its own worn days.
    func testUnwornDaysAreGapsNotCompacted() throws {
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: [23, 25, 27].contains(i) ? nil : 15)) }
        days.append(d(29, hrv: 60, rhr: 52, strain: 3))
        let r = ReadinessEngine.evaluate(days: days)
        // Acute = 4 worn days at 15; chronic = (21 × 5 + 4 × 15) / 25.
        XCTAssertEqual(try XCTUnwrap(r.acwr), 15.0 / (165.0 / 25.0), accuracy: 1e-9)
    }

    /// Too few worn days in the acute week (or the chronic month) gives no ratio rather than a stale one.
    func testMinimumCoverageInsteadOfCompaction() {
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 10)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: i >= 26 ? 10 : nil)) }   // 3 worn days
        days.append(d(29, hrv: 60, rhr: 52, strain: 10))
        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertNil(r.acwr)
        XCTAssertNil(r.monotony)
        XCTAssertNil(r.signals.first { $0.key == "acwr" })
    }

    func testRespRateRiseFlags() {
        // Today resp rate well above baseline (~14) → illness-ish watch/bad signal present.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayResp: 18))
        XCTAssertTrue(r.signals.contains { $0.key == "respRate" })
        XCTAssertEqual(r.signals.first { $0.key == "respRate" }?.evidence, "18.0 vs 14.0 rpm")
    }

    func testExplicitTodayWithoutMatchingRowIsInsufficient() {
        // Stale historical import: newest row is 2024-03-29, but the device's real calendar day is later.
        // An explicit `today` with no matching row must read INSUFFICIENT — NOT synthesize off the newest
        // stored (stale) row (issue #23/#24).
        let days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, today: "2026-06-08").level, .insufficient)
        // The day that IS present still computes (no regression for current data).
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days, today: "2024-03-29").level, .insufficient)
        // The legacy no-`today` path is unchanged — still falls back to the most recent row.
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days).level, .insufficient)
    }

    func testPhysiologyBaselineDoesNotReachBackAcrossLongWearGap() {
        var days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10, todayResp: 18)
        days.append(DailyMetric(day: "2024-06-01", totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
            restingHr: 46, avgHrv: 72, recovery: nil, strain: nil, exerciseCount: nil, respRateBpm: 18))
        let result = ReadinessEngine.evaluate(days: days, today: "2024-06-01")
        XCTAssertEqual(result.level, .insufficient)
        XCTAssertTrue(result.signals.isEmpty)
    }

    func testPhysiologyBaselineIncludesDayThirtyButExcludesDayThirtyOne() {
        let history = (1...7).map { d($0, hrv: Double(58 + $0 % 3), rhr: 50 + $0 % 3, strain: nil) }
        func evaluate(on target: String) -> ReadinessEngine.Readiness {
            let current = DailyMetric(day: target, totalSleepMin: nil, efficiency: nil,
                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                restingHr: 46, avgHrv: 72, recovery: nil, strain: nil, exerciseCount: nil)
            return ReadinessEngine.evaluate(days: history + [current], today: target)
        }
        // Mar 1 is 30 days before Mar 31, and 31 days before Apr 1. Losing this row leaves
        // only six valid baseline nights, below the seven-night coverage gate.
        XCTAssertTrue(evaluate(on: "2024-03-31").signals.contains { $0.key == "hrv" })
        XCTAssertTrue(evaluate(on: "2024-04-01").signals.isEmpty)
    }

    func testStatsHelpers() {
        XCTAssertEqual(ReadinessEngine.mean([2, 4, 6]), 4)
        XCTAssertEqual(ReadinessEngine.sampleSD([2, 4, 6])!, 2.0, accuracy: 0.0001)
        XCTAssertNil(ReadinessEngine.sampleSD([5]))
        XCTAssertNil(ReadinessEngine.mean([]))
    }
}
