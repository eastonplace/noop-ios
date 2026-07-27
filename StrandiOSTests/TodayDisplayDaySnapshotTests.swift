import XCTest
import WhoopStore
@testable import NOOP

/// Regression coverage for the Today presentation snapshot. It removes repeated body-time history scans
/// without changing Repository's logical-day / local-day rollover policy.
final class TodayDisplayDaySnapshotTests: XCTestCase {
    private func day(_ key: String, sleepMin: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: 50,
                    strain: 40, exerciseCount: nil)
    }

    func testSnapshotPreservesPreFourAMBankedLocalDay() {
        let logicalKey = "2026-06-13", localKey = "2026-06-14"
        let rows = [
            day(logicalKey, sleepMin: 400),
            day(localKey, sleepMin: 430),
        ]

        XCTAssertEqual(
            TodayView.resolveDisplayDay(days: rows, selectedDayOffset: 0,
                                        logicalKey: logicalKey, localKey: localKey,
                                        selectedDayKey: logicalKey)?.day,
            localKey)
    }

    func testSnapshotPreservesPreFourAMAntiBlankFallback() {
        let logicalKey = "2026-06-13", localKey = "2026-06-14"
        let rows = [
            day(logicalKey, sleepMin: 400),
            day(localKey, sleepMin: nil),
        ]

        XCTAssertEqual(
            TodayView.resolveDisplayDay(days: rows, selectedDayOffset: 0,
                                        logicalKey: logicalKey, localKey: localKey,
                                        selectedDayKey: logicalKey)?.day,
            logicalKey)
    }

    func testSnapshotUsesExplicitPastDayKey() {
        let rows = [
            day("2026-06-12", sleepMin: 390),
            day("2026-06-13", sleepMin: 400),
            day("2026-06-14", sleepMin: 430),
        ]

        XCTAssertEqual(
            TodayView.resolveDisplayDay(days: rows, selectedDayOffset: 2,
                                        logicalKey: "2026-06-14", localKey: "2026-06-14",
                                        selectedDayKey: "2026-06-12")?.day,
            "2026-06-12")
    }
}
