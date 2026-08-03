import XCTest
@testable import NOOP

final class CommittedAnalysisWindowTests: XCTestCase {
    func testMidnightCrossingIncludesBothCivilDays() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let start = try date(calendar, year: 2026, month: 7, day: 27, hour: 23, minute: 30)
        let end = try date(calendar, year: 2026, month: 7, day: 28, hour: 0, minute: 30)

        let days = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: start,
            maximumTimestamp: end,
            using: calendar
        )

        XCTAssertEqual(days, [day(2026, 7, 27), day(2026, 7, 28)])
    }

    func testLogicalDayUsesPreviousCivilDayBeforeFourAndCurrentCivilDayAtFour() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let beforeFour = try date(calendar, year: 2026, month: 7, day: 28, hour: 3, minute: 59)
        let exactlyFour = try date(calendar, year: 2026, month: 7, day: 28, hour: 4)

        let beforeFourDays = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: beforeFour,
            maximumTimestamp: beforeFour,
            using: calendar
        )
        let exactlyFourDays = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: exactlyFour,
            maximumTimestamp: exactlyFour,
            using: calendar
        )

        XCTAssertEqual(beforeFourDays, [day(2026, 7, 27), day(2026, 7, 28)])
        XCTAssertEqual(exactlyFourDays, [day(2026, 7, 28)])
    }

    func testSpringForwardUsesCalendarDaysNotElapsedTwentyFourHours() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let start = try date(calendar, year: 2026, month: 3, day: 7, hour: 23, minute: 30)
        let end = try date(calendar, year: 2026, month: 3, day: 8, hour: 4, minute: 30)

        let days = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: start,
            maximumTimestamp: end,
            using: calendar
        )

        XCTAssertEqual(days, [day(2026, 3, 7), day(2026, 3, 8)])
        XCTAssertEqual(end.timeIntervalSince(start), 4 * 3_600)
    }

    func testFallBackUsesCalendarDaysNotElapsedTwentyFourHours() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let start = try date(calendar, year: 2026, month: 10, day: 31, hour: 23, minute: 30)
        let end = try date(calendar, year: 2026, month: 11, day: 1, hour: 4, minute: 30)

        let days = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: start,
            maximumTimestamp: end,
            using: calendar
        )

        XCTAssertEqual(days, [day(2026, 10, 31), day(2026, 11, 1)])
        XCTAssertEqual(end.timeIntervalSince(start), 6 * 3_600)
    }

    func testTravelTimezoneUsesTheCalendarSuppliedAtPlanningTime() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let instant = try date(utc, year: 2026, month: 8, day: 12, hour: 4, minute: 30)
        let newYork = try calendar(timeZone: "America/New_York")
        let losAngeles = try calendar(timeZone: "America/Los_Angeles")

        let newYorkDays = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: instant,
            maximumTimestamp: instant,
            using: newYork
        )
        let losAngelesDays = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: instant,
            maximumTimestamp: instant,
            using: losAngeles
        )

        XCTAssertEqual(newYorkDays, [day(2026, 8, 11), day(2026, 8, 12)])
        XCTAssertEqual(losAngelesDays, [day(2026, 8, 11)])
    }

    func testSleepWindowCrossingMidnightKeepsPriorAndWakeCivilDays() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let bedtime = try date(calendar, year: 2026, month: 8, day: 10, hour: 22, minute: 45)
        let wake = try date(calendar, year: 2026, month: 8, day: 11, hour: 6, minute: 30)

        let days = try CommittedAnalysisWindow(
            minimumTimestamp: bedtime,
            maximumTimestamp: wake
        ).affectedDays(using: calendar)

        XCTAssertTrue(days.contains(day(2026, 8, 10)))
        XCTAssertTrue(days.contains(day(2026, 8, 11)))
    }

    func testExplicitNapAndMainNightDaysArePreservedWithoutSleepInference() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let start = try date(calendar, year: 2026, month: 8, day: 11, hour: 12)
        let end = try date(calendar, year: 2026, month: 8, day: 11, hour: 13)
        let napDay = day(2026, 8, 11)
        let mainNightDay = day(2026, 8, 10)

        let days = try CommittedAnalysisWindow(
            minimumTimestamp: start,
            maximumTimestamp: end,
            touchedCivilDays: [napDay, mainNightDay]
        ).affectedDays(using: calendar)

        XCTAssertTrue(days.contains(napDay))
        XCTAssertTrue(days.contains(mainNightDay))
        XCTAssertEqual(days.count, 2)
    }

    func testExplicitTimestampHealDaysAreAddedToTimestampExpansion() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 12, hour: 12)
        let healedDay = day(2026, 7, 1)

        let days = try CommittedAnalysisWindow.affectedDays(
            minimumTimestamp: timestamp,
            maximumTimestamp: timestamp,
            timestampHealDays: [healedDay],
            using: calendar
        )

        XCTAssertEqual(days, [day(2026, 8, 12), healedDay])
    }

    func testRequestAndMutationReceiptCarryOnlyOpaqueAnalysisMetadata() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 12, hour: 12)
        let lineage = AnalysisSourceDeviceLineage(sourceId: "whoop", deviceId: "strap-a")
        let request = CommittedAnalysisRequest(
            databaseInstanceId: "database-a",
            sourceDeviceLineage: lineage,
            throughReceiptGeneration: 42,
            minimumTimestamp: timestamp,
            maximumTimestamp: timestamp,
            timestampHealState: .completed
        )
        let mutation = AnalysisMutationReceipt(
            databaseInstanceId: request.databaseInstanceId,
            sourceDeviceLineage: lineage,
            consumedReceiptFrontier: AnalysisReceiptFrontier(
                generation: request.throughReceiptGeneration,
                timestamp: timestamp
            ),
            analyzedDays: try request.affectedDays(using: calendar).sorted(),
            algorithmBundleVersion: "contract-test-v1",
            changedDailyMetricIdentifiers: ["sleep", "sleep"],
            changedScoreIdentifiers: ["recovery"]
        )

        XCTAssertEqual(mutation.consumedReceiptGeneration, 42)
        XCTAssertEqual(mutation.changedDailyMetricIdentifiers, ["sleep"])
        XCTAssertEqual(mutation.changedScoreIdentifiers, ["recovery"])
        XCTAssertEqual(mutation.algorithmBundleVersion, "contract-test-v1")
    }

    private func calendar(timeZone identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> AnalysisCivilDay {
        AnalysisCivilDay(year: year, month: month, day: day)
    }
}
