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

    func testFitbitMalformedKnownDayEventsDoNotPublishAPartialTotal() throws {
        let result = WearableExportImporter.parse(brand: .fitbit, files: [
            "steps-a.json": try steps(["-1", "NaN", "1e9999", String(Int.max), "0", "120"]),
        ])
        XCTAssertTrue(result.days.isEmpty)
    }

    func testFitbitUnknownContributorInvalidatesAllSameDayFragments() throws {
        let malformed: [Any?] = [nil, NSNull(), "1e300", String(Int.max), "NaN", "inf", -1, -0.5, true, false, "bad", "0.5"]
        for value in malformed {
            var event: [String: Any] = ["dateTime": day + "T10:01:00Z"]
            if let value { event["value"] = value }
            let bad = try JSONSerialization.data(withJSONObject: [event])
            let good = try steps(["10"])
            for badFirst in [false, true] {
                var files = ["resting_heart_rate-day.json": try restingHR(), "steps-other-day.json": try steps(["25"], day: "2026-06-02")]
                if badFirst { files["steps-bad.json"] = bad; files["steps-good.json"] = good }
                else { files["steps-good.json"] = good; files["steps-bad.json"] = bad }
                let result = WearableExportImporter.parse(brand: .fitbit, files: files)
                let affected = try XCTUnwrap(result.days.first { $0.day == day })
                XCTAssertNil(affected.steps, "\(String(describing: value)); badFirst=\(badFirst)")
                XCTAssertEqual(affected.restingHr, 61)
                XCTAssertEqual(result.days.first { $0.day == "2026-06-02" }?.steps, 25)
            }
        }
    }

    func testFitbitUnknownEventCannotMakeAMixedIntradayTotalLookComplete() throws {
        for value: Any in ["1e300", String(Int.max), "NaN", "inf", -1, true, false] {
            for badFirst in [false, true] {
                let valid: [String: Any] = ["dateTime": day + "T10:00:00Z", "value": "10"]
                let invalid: [String: Any] = ["dateTime": day + "T10:01:00Z", "value": value]
                let data = try JSONSerialization.data(withJSONObject: badFirst ? [invalid, valid] : [valid, invalid])
                let result = WearableExportImporter.parse(brand: .fitbit, files: ["steps-mixed.json": data])
                XCTAssertTrue(result.days.isEmpty, "\(value); badFirst=\(badFirst)")
            }
        }
    }

    func testJSONBooleansCannotBecomeNumericStepsForAnyWearableBrand() throws {
        for value in [false, true] {
            let fitbit: [String: Data] = ["steps-bool.json": try JSONSerialization.data(withJSONObject: [
                ["dateTime": day + "T10:00:00Z", "value": value],
            ])]
            let garmin: [String: Data] = ["di_connect/daily.json": try JSONSerialization.data(withJSONObject: [
                ["calendarDate": day, "totalSteps": value],
            ])]
            let oura: [String: Data] = ["oura.json": try JSONSerialization.data(withJSONObject: [
                "daily_activity": [["day": day, "steps": value]],
            ])]
            for (brand, files) in [(WearableBrand.fitbit, fitbit), (.garmin, garmin), (.oura, oura)] {
                let result = WearableExportImporter.parse(brand: brand, files: files)
                XCTAssertNil(result.days.first?.steps, "\(brand): \(value)")
            }
        }
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

    func testFitbitObservedZeroRemainsAnImportableDailyMeasurement() throws {
        let data = try steps(["0", "0"])
        let result = WearableExportImporter.parse(brand: .fitbit, files: ["steps-zero.json": data])
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days.first?.steps, 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steps-zero-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertEqual(try WearableExportImporter().import(from: url).days.first?.steps, 0)
    }

    func testFitbitMissingNegativeAndNonFiniteEventsDoNotBecomeObservedZero() throws {
        let rejected: [Any?] = [nil, NSNull(), "-1", "-0.5", "NaN", "inf", "1e300", String(Int.max), "0.5"]
        for value in rejected {
            var event: [String: Any] = ["dateTime": day + "T10:00:00Z"]
            if let value { event["value"] = value }
            let data = try JSONSerialization.data(withJSONObject: [event])
            let result = WearableExportImporter.parse(brand: .fitbit, files: [
                "steps-invalid.json": data, "resting_heart_rate-day.json": try restingHR(),
            ])
            XCTAssertNil(result.days.first?.steps, "\(String(describing: value))")
            XCTAssertEqual(result.days.first?.restingHr, 61)
        }
    }

    private func garmin(_ records: [[String: Any]]) throws -> WearableImportResult {
        WearableExportImporter.parse(brand: .garmin, files: [
            "di_connect/daily.json": try JSONSerialization.data(withJSONObject: records),
        ])
    }

    func testGarminBothStepAliasesAcceptNumericAndStringObservedZero() throws {
        for key in ["steps", "totalSteps"] {
            for zero: Any in [0, "0"] {
                let result = try garmin([["calendarDate": day, key: zero, "restingHeartRate": 0, "averageStressLevel": 0]])
                XCTAssertEqual(result.days.first?.steps, 0, key)
                XCTAssertNil(result.days.first?.restingHr)
                XCTAssertNil(result.days.first?.avgStress)
            }
        }
    }

    func testGarminPrimaryObservedZeroWinsOverPositiveSecondaryAlias() throws {
        let result = try garmin([["calendarDate": day, "totalSteps": 0, "steps": 8421]])
        XCTAssertEqual(result.days.first?.steps, 0)
        let fallback = try garmin([["calendarDate": day, "totalSteps": "-0.5", "steps": 0]])
        XCTAssertEqual(fallback.days.first?.steps, 0, "an invalid primary alias still permits a valid secondary measurement")
    }

    func testGarminMissingNegativeAndNonFiniteStepsRemainUnknown() throws {
        let rejected: [Any?] = [nil, NSNull(), -1, -0.5, "NaN", "inf", "1e300", Int.max, "0.5"]
        for key in ["steps", "totalSteps"] {
            for value in rejected {
                var row: [String: Any] = ["calendarDate": day, "restingHeartRate": 61]
                if let value { row[key] = value }
                let result = try garmin([row])
                XCTAssertNil(result.days.first?.steps, "\(key): \(String(describing: value))")
                XCTAssertEqual(result.days.first?.restingHr, 61)
            }
        }
    }

    func testGarminObservedZeroReplacesEarlierSameFileStepsWithoutClearingHR() throws {
        let result = try garmin([
            ["calendarDate": day, "totalSteps": 8421, "restingHeartRate": 61],
            ["calendarDate": day, "totalSteps": 0],
        ])
        XCTAssertEqual(result.days.first?.steps, 0)
        XCTAssertEqual(result.days.first?.restingHr, 61)
    }

    func testGarminIntegerCoercionsStayRangeChecked() throws {
        let largest = try garmin([["calendarDate": day, "totalSteps": large, "restingHeartRate": large, "averageStressLevel": large]])
        XCTAssertEqual(largest.days.first?.steps, large)
        XCTAssertEqual(largest.days.first?.restingHr, large)
        XCTAssertEqual(largest.days.first?.avgStress, large)
        for invalid: Any in [Int.max, 1e300, "1e300", "inf", "NaN"] {
            let result = try garmin([["calendarDate": day, "totalSteps": invalid, "restingHeartRate": invalid, "averageStressLevel": invalid]])
            XCTAssertNil(result.days.first?.steps)
            XCTAssertNil(result.days.first?.restingHr)
            XCTAssertNil(result.days.first?.avgStress)
        }
    }

    func testGarminZeroHeartRateAndDirectAndNestedScoresRemainUnmeasured() throws {
        for score: [String: Any] in [["overallSleepScore": 0], ["sleepScores": ["overall": ["value": 0]]]] {
            var sleep: [String: Any] = ["calendarDate": day, "sleepStartTimestampGMT": 1_780_272_000_000,
                                       "sleepEndTimestampGMT": 1_780_275_600_000, "deepSleepSeconds": 60, "restingHeartRate": 0]
            sleep.merge(score) { _, new in new }
            let result = WearableExportImporter.parse(brand: .garmin, files: [
                "sleepdata.json": try JSONSerialization.data(withJSONObject: [sleep]),
            ])
            XCTAssertEqual(result.sleeps.count, 1)
            XCTAssertNil(result.sleeps.first?.sleepScore)
            XCTAssertNil(result.sleeps.first?.lowestHr)
            XCTAssertNil(result.days.first?.restingHr)
        }
    }
}
