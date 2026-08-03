import XCTest
import WhoopStore
@testable import NOOP

final class DailyMetricProvenancePreservationTests: XCTestCase {
    private func metric() -> DailyMetric {
        DailyMetric(
            day: "2026-08-03", totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 95,
            lightMin: 245, disturbances: 2, restingHr: 52, avgHrv: 68, recovery: 76,
            strain: 14.2, exerciseCount: 1, spo2Pct: 97, skinTempDevC: 0.2,
            respRateBpm: 14.1, steps: 8_000, activeKcalEst: 640, spo2Red: 110,
            spo2Ir: 120, strainVersion: 2)
    }

    func testRecoveryReplacementPreservesStrainV2Provenance() {
        let result = metric().with(recovery: 84, skinTempDevC: -0.3)

        XCTAssertEqual(result.recovery, 84)
        XCTAssertEqual(result.skinTempDevC, -0.3)
        XCTAssertEqual(result.strain, 14.2)
        XCTAssertEqual(result.strainVersion, 2)
    }

    func testSleepReplacementPreservesStrainV2Provenance() {
        let result = metric().with(
            totalSleepMin: 455, efficiency: 0.94, deepMin: 100, remMin: 105, lightMin: 250)

        XCTAssertEqual(result.totalSleepMin, 455)
        XCTAssertEqual(result.efficiency, 0.94)
        XCTAssertEqual(result.deepMin, 100)
        XCTAssertEqual(result.remMin, 105)
        XCTAssertEqual(result.lightMin, 250)
        XCTAssertEqual(result.strain, 14.2)
        XCTAssertEqual(result.strainVersion, 2)
    }
}
