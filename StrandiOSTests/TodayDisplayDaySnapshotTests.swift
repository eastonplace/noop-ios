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

    func testNotificationPinsExactDayBeforeFourAMWithAndWithoutBankedLocalNight() {
        let logical = "2026-10-19", local = "2026-10-20"
        for localSleep: Double? in [430, nil] {
            let rows = [day(logical, sleepMin: 400), day(local, sleepMin: localSleep)]
            for requested in [logical, local] {
                XCTAssertEqual(TodayView.resolveDisplayDay(days: rows, selectedDayOffset: 0,
                    logicalKey: logical, localKey: local, selectedDayKey: requested,
                    exactDaySelection: true)?.day, requested)
            }
        }
    }

    func testNotificationCivilDayResolvesToSameRecordAfterTimezoneChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let selected = "2026-10-20"
        let opened = try XCTUnwrap(TodayView.notificationSelectionDate(dayKey: selected, calendar: calendar))
        XCTAssertEqual(Repository.localDayKey(opened, calendar: calendar), selected)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(Repository.localDayKey(opened, calendar: calendar), "2026-10-19")
        let afterTravel = try XCTUnwrap(TodayView.notificationSelectionDate(dayKey: selected, calendar: calendar))
        XCTAssertEqual(Repository.localDayKey(afterTravel, calendar: calendar), selected)
        let rows = [day("2026-10-19", sleepMin: 400), day(selected, sleepMin: 430)]
        XCTAssertEqual(TodayView.resolveDisplayDay(days: rows, selectedDayOffset: 0,
            logicalKey: "2026-10-19", localKey: "2026-10-19", selectedDayKey: selected,
            exactDaySelection: true)?.day, selected)
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

    func testFirstPaintAcceptsPreviousLogicalDayAtMidnightAndFourAM() {
        XCTAssertTrue(TodayView.acceptsFirstPaintSnapshot(
            displayDay: "2026-06-13", selectedDayOffset: 0,
            logicalKey: "2026-06-13", localKey: "2026-06-14"
        ))
        XCTAssertTrue(TodayView.acceptsFirstPaintSnapshot(
            displayDay: "2026-06-13", selectedDayOffset: 0,
            logicalKey: "2026-06-14", localKey: "2026-06-14"
        ))
    }

    func testFirstPaintRejectsFutureAndHistoricalSnapshots() {
        XCTAssertFalse(TodayView.acceptsFirstPaintSnapshot(
            displayDay: "2026-06-15", selectedDayOffset: 0,
            logicalKey: "2026-06-14", localKey: "2026-06-14"
        ))
        XCTAssertFalse(TodayView.acceptsFirstPaintSnapshot(
            displayDay: "2026-06-13", selectedDayOffset: 1,
            logicalKey: "2026-06-14", localKey: "2026-06-14"
        ))
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
