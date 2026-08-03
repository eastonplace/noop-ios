import Foundation
import XCTest
@testable import NOOP
import WhoopStore

final class HistoricalReceiptAnalysisPlannerTests: XCTestCase {
    func testOneNightCrossingFourAMUsesDecodedInstantsInsteadOfUTCDays() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let bedtime = try date(calendar, year: 2026, month: 7, day: 27, hour: 22, minute: 30)
        let wake = try date(calendar, year: 2026, month: 7, day: 28, hour: 4, minute: 30)
        let receipt = receipt(
            generation: 1,
            minimumTimestamp: unix(bedtime),
            maximumTimestamp: unix(wake),
            touchedDays: ["2099-01-01"]
        )

        let plan = try HistoricalReceiptAnalysisPlanner.plan(receipts: [receipt], using: calendar)
        let window = try XCTUnwrap(plan.window)
        let days = try window.affectedDays(using: calendar)

        XCTAssertEqual(plan.throughGeneration, 1)
        XCTAssertEqual(window.minimumTimestamp, bedtime)
        XCTAssertEqual(window.maximumTimestamp, wake)
        XCTAssertEqual(days, [day(2026, 7, 27), day(2026, 7, 28)])
        XCTAssertFalse(days.contains(day(2099, 1, 1)))
    }

    func testMultipleProductiveReceiptsMergeDecodedTimestampBoundsAndKeepFinalGeneration() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let firstMinimum = try date(calendar, year: 2026, month: 8, day: 1, hour: 22)
        let firstMaximum = try date(calendar, year: 2026, month: 8, day: 2, hour: 1)
        let secondMinimum = try date(calendar, year: 2026, month: 8, day: 3, hour: 10)
        let secondMaximum = try date(calendar, year: 2026, month: 8, day: 3, hour: 11)
        let final = receipt(generation: 12, insertedRows: HistoricalStreamInsertCounts(), isFinal: true)

        let plan = try HistoricalReceiptAnalysisPlanner.plan(receipts: [
            receipt(generation: 10, minimumTimestamp: unix(firstMinimum), maximumTimestamp: unix(firstMaximum)),
            receipt(generation: 11, minimumTimestamp: unix(secondMinimum), maximumTimestamp: unix(secondMaximum)),
            final,
        ], using: calendar)
        let window = try XCTUnwrap(plan.window)

        XCTAssertEqual(plan.databaseInstanceId, "database-a")
        XCTAssertEqual(plan.scope, HistoricalCursorScope(
            deviceId: "strap-a", lineage: "lineage-a", cursorEpoch: 0, trimScope: "historical"))
        XCTAssertEqual(plan.throughGeneration, 12)
        XCTAssertEqual(window.minimumTimestamp, firstMinimum)
        XCTAssertEqual(window.maximumTimestamp, secondMaximum)
    }

    func testScopeMismatchIsRejected() throws {
        let calendar = try calendar(timeZone: "UTC")
        let first = receipt(generation: 1, lineage: "lineage-a")
        let second = receipt(generation: 2, lineage: "lineage-b")

        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [first, second], using: calendar
        )) { error in
            XCTAssertEqual(error as? HistoricalReceiptAnalysisPlannerError, .mixedScope)
        }
    }

    func testDatabaseMismatchIsRejected() throws {
        let calendar = try calendar(timeZone: "UTC")
        let first = receipt(generation: 1, databaseInstanceId: "database-a")
        let second = receipt(generation: 2, databaseInstanceId: "database-b")

        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [first, second], using: calendar
        )) { error in
            XCTAssertEqual(error as? HistoricalReceiptAnalysisPlannerError, .mixedDatabaseInstance)
        }
    }

    func testZeroRowFinalReceiptAdvancesThroughGenerationWithoutWideningAnalysis() throws {
        let calendar = try calendar(timeZone: "UTC")
        let minimum = try date(calendar, year: 2026, month: 8, day: 1, hour: 10)
        let maximum = try date(calendar, year: 2026, month: 8, day: 1, hour: 11)
        let productive = receipt(
            generation: 41,
            minimumTimestamp: unix(minimum),
            maximumTimestamp: unix(maximum)
        )
        let emptyFinal = receipt(
            generation: 42,
            insertedRows: HistoricalStreamInsertCounts(),
            minimumTimestamp: 9_999_999,
            maximumTimestamp: 9_999_999,
            touchedDays: ["1900-01-01"],
            rawRange: HistoricalRawRangeEvidence(
                source: .receivedFrames,
                minReceivedTs: 1,
                maxReceivedTs: 2,
                frameCount: 1,
                byteCount: 1,
                hasHistoryEnd: true
            ),
            isFinal: true
        )

        let plan = try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [productive, emptyFinal], using: calendar
        )
        let window = try XCTUnwrap(plan.window)

        XCTAssertEqual(plan.throughGeneration, 42)
        XCTAssertEqual(window.minimumTimestamp, minimum)
        XCTAssertEqual(window.maximumTimestamp, maximum)
    }

    func testAllEmptyReceiptsProduceExplicitNoAnalysisOutcome() throws {
        let calendar = try calendar(timeZone: "UTC")
        let plan = try HistoricalReceiptAnalysisPlanner.plan(receipts: [
            receipt(generation: 70, insertedRows: HistoricalStreamInsertCounts()),
            receipt(generation: 71, insertedRows: HistoricalStreamInsertCounts(), isFinal: true),
        ], using: calendar)

        XCTAssertEqual(plan.outcome, .noAnalysis)
        XCTAssertTrue(plan.isNoAnalysis)
        XCTAssertFalse(plan.requiresAnalysis)
        XCTAssertNil(plan.window)
        XCTAssertEqual(plan.throughGeneration, 71)
    }

    func testProductiveReceiptMissingDecodedTimestampsIsRejectedEvenWithRawRangeEvidence() throws {
        let calendar = try calendar(timeZone: "UTC")
        let receipt = receipt(
            generation: 5,
            minimumTimestamp: nil,
            maximumTimestamp: nil,
            rawRange: HistoricalRawRangeEvidence(
                source: .retainedRawBatch,
                minReceivedTs: 1_700_000_000,
                maxReceivedTs: 1_700_000_100,
                frameCount: 2,
                byteCount: 20,
                hasHistoryEnd: true
            )
        )

        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt], using: calendar
        )) { error in
            XCTAssertEqual(
                error as? HistoricalReceiptAnalysisPlannerError,
                .productiveReceiptMissingTimestampEvidence(5)
            )
        }
    }

    func testTimestampHealRequiresAnExplicitWindowInsteadOfInventingDates() throws {
        let calendar = try calendar(timeZone: "UTC")
        let minimum = try date(calendar, year: 2026, month: 8, day: 1, hour: 10)
        let maximum = try date(calendar, year: 2026, month: 8, day: 1, hour: 11)
        let receipt = receipt(
            generation: 6,
            minimumTimestamp: unix(minimum),
            maximumTimestamp: unix(maximum),
            touchedDays: ["2026-08-01"],
            timestampHeal: HistoricalTimestampHeal(rawRowsDeleted: 1)
        )

        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt], using: calendar
        )) { error in
            XCTAssertEqual(
                error as? HistoricalReceiptAnalysisPlannerError,
                .timestampHealRequiresExplicitWindow(6)
            )
        }
    }

    func testDecoderDroppedRecordDoesNotBlockDecodedTimestampWindow() throws {
        let calendar = try calendar(timeZone: "UTC")
        let minimum = try date(calendar, year: 2026, month: 8, day: 2, hour: 10)
        let maximum = try date(calendar, year: 2026, month: 8, day: 2, hour: 11)
        let receipt = receipt(
            generation: 7,
            minimumTimestamp: unix(minimum),
            maximumTimestamp: unix(maximum),
            timestampHeal: HistoricalTimestampHeal(droppedRecordCount: 1)
        )

        let plan = try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt], using: calendar
        )

        XCTAssertEqual(plan.window?.minimumTimestamp, minimum)
        XCTAssertEqual(plan.window?.maximumTimestamp, maximum)
        XCTAssertEqual(plan.throughGeneration, 7)
    }

    func testLegacyReceiptWithoutDecodedTimestampEnvelopeAdvancesWithoutAnalysis() throws {
        let calendar = try calendar(timeZone: "UTC")
        let receipt = receipt(
            generation: 8,
            fingerprint: "legacy:receipt-8",
            minimumTimestamp: nil,
            maximumTimestamp: nil
        )

        let plan = try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt], using: calendar
        )

        XCTAssertEqual(plan.outcome, .noAnalysis)
        XCTAssertEqual(plan.throughGeneration, 8)
        XCTAssertTrue(plan.isNoAnalysis)
    }

    func testRejectsInvalidDatabaseIdsAndGenerationOrder() throws {
        let calendar = try calendar(timeZone: "UTC")

        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt(generation: 1, databaseInstanceId: "   ")], using: calendar
        )) { error in
            XCTAssertEqual(error as? HistoricalReceiptAnalysisPlannerError, .emptyDatabaseInstanceId)
        }
        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt(generation: 1, databaseInstanceId: "database\n-a")], using: calendar
        )) { error in
            XCTAssertEqual(error as? HistoricalReceiptAnalysisPlannerError, .invalidDatabaseInstanceId)
        }
        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt(generation: 2), receipt(generation: 2)], using: calendar
        )) { error in
            XCTAssertEqual(error as? HistoricalReceiptAnalysisPlannerError, .duplicateGeneration)
        }
        XCTAssertThrowsError(try HistoricalReceiptAnalysisPlanner.plan(
            receipts: [receipt(generation: 2), receipt(generation: 1)], using: calendar
        )) { error in
            XCTAssertEqual(error as? HistoricalReceiptAnalysisPlannerError, .nonmonotonicGeneration)
        }
    }

    func testSpringForwardUsesGregorianCivilDaysForPlannerWindow() throws {
        let calendar = try calendar(timeZone: "America/New_York")
        let minimum = try date(calendar, year: 2026, month: 3, day: 7, hour: 23, minute: 30)
        let maximum = try date(calendar, year: 2026, month: 3, day: 8, hour: 4, minute: 30)
        let plan = try HistoricalReceiptAnalysisPlanner.plan(receipts: [receipt(
            generation: 20,
            minimumTimestamp: unix(minimum),
            maximumTimestamp: unix(maximum)
        )], using: calendar)

        let days = try XCTUnwrap(plan.window).affectedDays(using: calendar)

        XCTAssertEqual(days, [day(2026, 3, 7), day(2026, 3, 8)])
        XCTAssertEqual(maximum.timeIntervalSince(minimum), 4 * 3_600)
    }

    func testTravelTimezoneIsAppliedWhenWindowExpandsNotWhenReceiptIsDecoded() throws {
        let utc = try calendar(timeZone: "UTC")
        let instant = try date(utc, year: 2026, month: 8, day: 12, hour: 4, minute: 30)
        let newYork = try calendar(timeZone: "America/New_York")
        let losAngeles = try calendar(timeZone: "America/Los_Angeles")
        let plan = try HistoricalReceiptAnalysisPlanner.plan(receipts: [receipt(
            generation: 21,
            minimumTimestamp: unix(instant),
            maximumTimestamp: unix(instant)
        )], using: newYork)
        let window = try XCTUnwrap(plan.window)

        XCTAssertEqual(
            try window.affectedDays(using: newYork),
            [day(2026, 8, 11), day(2026, 8, 12)]
        )
        XCTAssertEqual(
            try window.affectedDays(using: losAngeles),
            [day(2026, 8, 11)]
        )
    }

    private func receipt(
        generation: Int64,
        insertedRows: HistoricalStreamInsertCounts = HistoricalStreamInsertCounts(hr: 1),
        databaseInstanceId: String = "database-a",
        fingerprint: String? = nil,
        deviceId: String = "strap-a",
        lineage: String = "lineage-a",
        cursorEpoch: Int = 0,
        trimScope: String = HistoricalCursorScope.defaultTrimScope,
        minimumTimestamp: Int? = 1_700_000_000,
        maximumTimestamp: Int? = 1_700_000_100,
        touchedDays: [String] = [],
        rawRange: HistoricalRawRangeEvidence? = nil,
        timestampHeal: HistoricalTimestampHeal? = nil,
        isFinal: Bool = false
    ) -> HistoricalDataCommitReceipt {
        HistoricalDataCommitReceipt(
            receiptId: "receipt-\(generation)",
            generation: generation,
            databaseInstanceId: databaseInstanceId,
            deviceId: deviceId,
            trim: max(0, Int(generation)),
            chunkEndUnix: maximumTimestamp ?? 1_700_000_000,
            committedAt: 1_700_000_200 + max(0, Int(generation)),
            rawBatchId: nil,
            insertedRows: insertedRows,
            fingerprint: fingerprint ?? "fingerprint-\(generation)",
            lineage: lineage,
            cursorEpoch: cursorEpoch,
            trimScope: trimScope,
            minDecodedTs: minimumTimestamp,
            maxDecodedTs: maximumTimestamp,
            touchedDays: touchedDays,
            decodedRows: insertedRows,
            rawRange: rawRange,
            timestampHeal: timestampHeal,
            isFinal: isFinal
        )
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
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    private func unix(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> AnalysisCivilDay {
        AnalysisCivilDay(year: year, month: month, day: day)!
    }
}
