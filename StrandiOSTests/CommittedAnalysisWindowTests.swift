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

    func testImpossibleCivilDateIsRejectedInsteadOfNormalized() throws {
        let gregorianCalendar = try calendar(timeZone: "America/New_York")

        XCTAssertNil(AnalysisCivilDay(year: 2026, month: 2, day: 30))

        let invalidPayload = Data(#"{"year":2026,"month":2,"day":30}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AnalysisCivilDay.self, from: invalidPayload))

        let validDay = try XCTUnwrap(AnalysisCivilDay(year: 2026, month: 2, day: 28))
        XCTAssertEqual(validDay.date(in: gregorianCalendar), try date(gregorianCalendar, year: 2026, month: 2, day: 28, hour: 0))
    }

    func testCivilDaySerializationPreservesGregorianTimezoneAndLegacyValues() throws {
        let gregorianCalendar = try calendar(timeZone: "America/New_York")
        let gregorianDate = try date(gregorianCalendar, year: 2026, month: 2, day: 28, hour: 0)
        let gregorianDay = try XCTUnwrap(AnalysisCivilDay(date: gregorianDate, calendar: gregorianCalendar))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decodedGregorian = try decoder.decode(
            AnalysisCivilDay.self,
            from: encoder.encode(gregorianDay)
        )

        XCTAssertEqual(decodedGregorian, gregorianDay)
        XCTAssertEqual(decodedGregorian.date(in: gregorianCalendar), gregorianDate)
        XCTAssertEqual(decodedGregorian.calendarIdentifier, .gregorian)

        let legacyGregorian = try decoder.decode(
            AnalysisCivilDay.self,
            from: Data(#"{"year":2026,"month":2,"day":28}"#.utf8)
        )
        XCTAssertEqual(legacyGregorian, gregorianDay)

        let window = CommittedAnalysisWindow(touchedCivilDays: [gregorianDay])
        let decodedWindow = try decoder.decode(
            CommittedAnalysisWindow.self,
            from: encoder.encode(window)
        )
        XCTAssertEqual(decodedWindow, window)
    }

    func testNonGregorianCalendarsAreRejectedByCivilDaysAndPlanning() throws {
        let identifiers: [Calendar.Identifier] = [.japanese, .chinese, .hebrew]

        for identifier in identifiers {
            let nonGregorianCalendar = try calendar(identifier: identifier, timeZone: "UTC")

            XCTAssertNil(
                AnalysisCivilDay(year: 2026, month: 1, day: 1, calendar: nonGregorianCalendar),
                "Expected \(identifier) year/month/day construction to be rejected."
            )
            XCTAssertNil(
                AnalysisCivilDay(date: Date(timeIntervalSinceReferenceDate: 0), calendar: nonGregorianCalendar),
                "Expected \(identifier) date construction to be rejected."
            )
            XCTAssertThrowsError(try CommittedAnalysisWindow.affectedDays(using: nonGregorianCalendar)) { error in
                XCTAssertEqual(error as? CommittedAnalysisWindowError, .nonGregorianCalendar)
            }
        }
    }

    func testCivilDayDecoderRejectsExplicitNullAndNonGregorianIdentifiers() throws {
        let decoder = JSONDecoder()
        let explicitNull = Data(#"{"year":2026,"month":2,"day":28,"calendarIdentifier":null}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(AnalysisCivilDay.self, from: explicitNull))

        let japanese = Data(#"{"year":2026,"month":2,"day":28,"calendarIdentifier":{"japanese":{}}}"#.utf8)
        let chinese = Data(#"{"year":2026,"month":2,"day":28,"calendarIdentifier":{"chinese":{}}}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(AnalysisCivilDay.self, from: japanese))
        XCTAssertThrowsError(try decoder.decode(AnalysisCivilDay.self, from: chinese))
    }

    func testTimestampExpansionRejectsAnUnboundedHistoryRange() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let start = try date(calendar, year: 2000, month: 1, day: 1, hour: 0)
        let end = try date(calendar, year: 2100, month: 1, day: 1, hour: 0)

        XCTAssertThrowsError(try CommittedAnalysisWindow(
            minimumTimestamp: start,
            maximumTimestamp: end
        ).affectedDays(using: calendar)) { error in
            XCTAssertEqual(error as? CommittedAnalysisWindowError, .tooManyAffectedDays)
        }
    }

    func testAnalysisFenceConstructorsRejectInvalidValues() throws {
        XCTAssertThrowsError(try AnalysisSourceDeviceLineage(sourceId: "")) { error in
            XCTAssertEqual(error as? AnalysisFenceValidationError, .emptySourceId)
        }
        XCTAssertThrowsError(try AnalysisReceiptFrontier(generation: -1)) { error in
            XCTAssertEqual(error as? AnalysisFenceValidationError, .invalidGeneration)
        }

        let lineage = try AnalysisSourceDeviceLineage(sourceId: "whoop", deviceId: "strap-a")
        XCTAssertThrowsError(try CommittedAnalysisRequest(
            databaseInstanceId: "",
            sourceDeviceLineage: lineage,
            throughReceiptGeneration: 0
        )) { error in
            XCTAssertEqual(error as? AnalysisFenceValidationError, .emptyDatabaseInstanceId)
        }
        XCTAssertThrowsError(try CommittedAnalysisRequest(
            databaseInstanceId: "database-a",
            sourceDeviceLineage: lineage,
            throughReceiptGeneration: -1
        )) { error in
            XCTAssertEqual(error as? AnalysisFenceValidationError, .invalidGeneration)
        }

        let frontier = try AnalysisReceiptFrontier(generation: 0)
        XCTAssertThrowsError(try AnalysisMutationReceipt(
            databaseInstanceId: "database-a",
            sourceDeviceLineage: lineage,
            consumedReceiptFrontier: frontier,
            analyzedDays: [],
            algorithmBundleVersion: ""
        )) { error in
            XCTAssertEqual(error as? AnalysisFenceValidationError, .emptyAlgorithmBundleVersion)
        }
        XCTAssertThrowsError(try AnalysisMutationReceipt(
            databaseInstanceId: "",
            sourceDeviceLineage: lineage,
            consumedReceiptFrontier: frontier,
            analyzedDays: [],
            algorithmBundleVersion: "contract-test-v1"
        )) { error in
            XCTAssertEqual(error as? AnalysisFenceValidationError, .emptyDatabaseInstanceId)
        }
    }

    func testRequestAndMutationReceiptCarryOnlyOpaqueAnalysisMetadata() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 12, hour: 12)
        let lineage = try AnalysisSourceDeviceLineage(sourceId: "whoop", deviceId: "strap-a")
        let request = try CommittedAnalysisRequest(
            databaseInstanceId: "database-a",
            sourceDeviceLineage: lineage,
            throughReceiptGeneration: 42,
            minimumTimestamp: timestamp,
            maximumTimestamp: timestamp,
            timestampHealState: .completed
        )
        let mutation = try AnalysisMutationReceipt(
            databaseInstanceId: request.databaseInstanceId,
            sourceDeviceLineage: lineage,
            consumedReceiptFrontier: try AnalysisReceiptFrontier(
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

    private func calendar(
        identifier: Calendar.Identifier = .gregorian,
        timeZone timeZoneIdentifier: String
    ) throws -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneIdentifier))
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
        AnalysisCivilDay(year: year, month: month, day: day)!
    }
}
