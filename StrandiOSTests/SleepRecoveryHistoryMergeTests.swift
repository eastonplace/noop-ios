import XCTest
import WhoopStore
@testable import NOOP

final class SleepRecoveryHistoryMergeTests: XCTestCase {
    private func row(
        day: String,
        sleep: Double? = nil,
        rhr: Int? = nil,
        hrv: Double? = nil,
        recovery: Double? = nil,
        strain: Double? = nil,
        steps: Int? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: sleep,
            efficiency: sleep.map { _ in 0.88 },
            deepMin: sleep.map { _ in 70 },
            remMin: sleep.map { _ in 90 },
            lightMin: sleep.map { _ in 260 },
            disturbances: sleep.map { _ in 3 },
            restingHr: rhr,
            avgHrv: hrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: strain.map { _ in 1 },
            steps: steps,
            strainVersion: strain.map { _ in 2 })
    }

    func testImportedNilDriversDoNotEraseComputedBaselineValues() throws {
        let computed = row(day: "2026-07-25", sleep: 420, rhr: 51, hrv: 64, recovery: 72, strain: 45, steps: 8_000)
        let imported = row(day: "2026-07-25", sleep: 430, rhr: nil, hrv: nil, recovery: 78, strain: nil, steps: nil)

        let merged = try XCTUnwrap(SleepRecoveryHistoryMerge.merge(
            computed: [computed], imported: [imported]).first)

        XCTAssertEqual(merged.totalSleepMin, 430, "present imported sleep remains authoritative")
        XCTAssertEqual(merged.recovery, 78, "present imported recovery remains authoritative")
        XCTAssertEqual(merged.restingHr, 51, "computed RHR fills an imported nil")
        XCTAssertEqual(merged.avgHrv, 64, "computed HRV fills an imported nil")
        XCTAssertEqual(merged.strain, 45)
        XCTAssertEqual(merged.steps, 8_000)
    }

    func testImportedNonNilDriversStillWin() throws {
        let computed = row(day: "2026-07-25", rhr: 51, hrv: 64)
        let imported = row(day: "2026-07-25", rhr: 55, hrv: 58)

        let merged = try XCTUnwrap(SleepRecoveryHistoryMerge.merge(
            computed: [computed], imported: [imported]).first)

        XCTAssertEqual(merged.restingHr, 55)
        XCTAssertEqual(merged.avgHrv, 58)
    }

    func testDistinctDaysRemainChronological() {
        let rows = SleepRecoveryHistoryMerge.merge(
            computed: [row(day: "2026-07-26", hrv: 60)],
            imported: [row(day: "2026-07-24", hrv: 58)])
        XCTAssertEqual(rows.map(\.day), ["2026-07-24", "2026-07-26"])
    }
}
