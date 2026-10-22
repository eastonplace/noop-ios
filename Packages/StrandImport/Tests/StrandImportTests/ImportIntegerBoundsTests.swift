import XCTest
@testable import StrandImport

/// Aggregate arithmetic must fail through the existing malformed-input contracts, never trap or
/// publish a wrapped, capped or partial total. Individually representable boundary values stay valid.
final class ImportIntegerBoundsTests: XCTestCase {
    private let day = "2026-06-01"
    private let large = 9_000_000_000_000_000_000

    private func steps(_ values: [String], day: String = "2026-06-01") throws -> Data {
        try JSONSerialization.data(withJSONObject: values.map { ["dateTime": day + "T10:00:00Z", "value": $0] })
    }

    private func restingHR() throws -> Data {
        try JSONSerialization.data(withJSONObject: [["dateTime": day, "value": ["value": 61]]])
    }

    func testFitbitIntradayOverflowOmitsWholeStepTotalAndPreservesOtherMetricsAndDays() throws {
        let result = WearableExportImporter.parse(brand: .fitbit, files: [
            "steps-overflow.json": try steps([String(large), String(large), "7"]),
            "steps-valid.json": try steps(["120", "5"], day: "2026-06-02"),
            "resting_heart_rate-2026-06-01.json": try restingHR(),
        ])
        XCTAssertEqual(result.days.count, 2)
        let affected = try XCTUnwrap(result.days.first { $0.day == day })
        XCTAssertNil(affected.steps, "the unrepresentable day must not retain a partial or capped step total")
        XCTAssertEqual(affected.restingHr, 61)
        XCTAssertEqual(result.days.first { $0.day == "2026-06-02" }?.steps, 125)
    }

    func testFitbitCrossFileOverflowCannotBeResurrectedByAnotherValidFragment() throws {
        let fragments = [
            ("steps-a.json", try steps([String(large)])),
            ("steps-b.json", try steps([String(large)])),
            ("steps-c.json", try steps(["7"])),
        ]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var files = ["resting_heart_rate-day.json": try restingHR()]
            for index in order { files[fragments[index].0] = fragments[index].1 }
            let result = WearableExportImporter.parse(brand: .fitbit, files: files)
            let affected = try XCTUnwrap(result.days.first { $0.day == day })
            XCTAssertNil(affected.steps, "insertion order \(order)")
            XCTAssertEqual(affected.restingHr, 61)
        }
    }

    func testFitbitExactIntMaximumRemainsValidWithinAndAcrossFiles() throws {
        // The existing scalar helper coerces through Double. These two large scalars are exactly
        // representable; the final small scalar reaches Int.max without any scalar-rounding ambiguity.
        let remainder = (Int.max - 1_023) - large
        let within = WearableExportImporter.parse(brand: .fitbit, files: [
            "steps-a.json": try steps([String(large), String(remainder), "1023"]),
        ])
        XCTAssertEqual(within.days.first?.steps, Int.max)
        let across = WearableExportImporter.parse(brand: .fitbit, files: [
            "steps-a.json": try steps([String(large), String(remainder)]),
            "steps-b.json": try steps(["1023"]),
        ])
        XCTAssertEqual(across.days.first?.steps, Int.max)
    }

    func testFitbitOneBeyondExactMaximumOmitsTheDayInsteadOfCapping() throws {
        let remainder = (Int.max - 1_023) - large
        let result = WearableExportImporter.parse(brand: .fitbit, files: [
            "steps-a.json": try steps([String(large), String(remainder), "1023", "1"]),
        ])
        XCTAssertTrue(result.days.isEmpty)
    }

    func testFitbitOnlyOverflowedDayUsesExistingEmptyExportError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steps-overflow-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try steps([String(large), String(large)]).write(to: url)
        XCTAssertThrowsError(try WearableExportImporter().import(from: url)) { error in
            guard case ImportError.emptyExport = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testFitbitUnparseableIndividualEventsKeepExistingSkipContract() throws {
        let result = WearableExportImporter.parse(brand: .fitbit, files: [
            "steps-a.json": try steps(["-1", "NaN", "1e9999", String(Int.max), "0", "120"]),
        ])
        XCTAssertEqual(result.days.first?.steps, 120)
    }

    private func liftosaur(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["history": records])
    }

    private func record(_ reps: [Any], start: Int = 1_748_772_000_000) -> [String: Any] {
        ["startTime": start, "entries": [["sets": reps.map { ["completedReps": $0] }]]]
    }

    func testLiftosaurOverflowSkipsWholeRecordAndKeepsValidSessionAndSkipCount() throws {
        let bad = record([Int.max, 1])
        let good: [String: Any] = ["startTime": 1_748_858_400_000, "entries": [["sets": [["completedReps": 3, "weight": 10]]]]]
        let result = LiftingImporter.parseLiftosaur(data: try liftosaur([bad, good]))
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.sessionCount, 1)
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.totalReps, 3)
        XCTAssertEqual(session.setCount, 1)
        XCTAssertEqual(session.volumeLoadKg, 30)
        XCTAssertEqual(result.earliest, session.start)
        XCTAssertEqual(result.latest, session.start)
    }

    func testLiftosaurOverflowAcrossEntriesAlsoSkipsWholeRecord() throws {
        let input: [String: Any] = ["startTime": 1_748_772_000_000, "entries": [
            ["sets": [["completedReps": String(Int.max)]]],
            ["sets": [["completedReps": "1"]]],
        ]]
        let result = LiftingImporter.parseLiftosaur(data: try liftosaur([input]))
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNil(result.earliest)
        XCTAssertNil(result.latest)
    }

    func testLiftosaurExactMaximumNumericAndStringTotalsRemainValid() throws {
        for reps: [Any] in [[Int.max], [Int.max - 1, 1], [String(Int.max - 1), "1"]] {
            let result = LiftingImporter.parseLiftosaur(data: try liftosaur([record(reps)]))
            XCTAssertEqual(result.skipped, 0)
            XCTAssertEqual(result.sessions.first?.totalReps, Int.max)
            XCTAssertEqual(result.sessions.first?.setCount, reps.count)
        }
    }

    func testLiftosaurZeroNegativeAndPlannedSetsDoNotChangeValidBoundaryTotal() throws {
        let input: [String: Any] = ["startTime": 1_748_772_000_000, "entries": [["sets": [
            ["completedReps": Int.max], ["completedReps": Int.min],
            ["completedReps": 0], ["reps": 10],
        ]]]]
        let result = LiftingImporter.parseLiftosaur(data: try liftosaur([input]))
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.sessions.first?.totalReps, Int.max)
        XCTAssertEqual(result.sessions.first?.setCount, 1)
    }
}
