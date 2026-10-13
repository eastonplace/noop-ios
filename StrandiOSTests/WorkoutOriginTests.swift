import XCTest
import WhoopStore
@testable import NOOP

final class WorkoutOriginTests: XCTestCase {
    /// A run recorded live in the app, as `AppModel.endWorkout` stores it.
    private func recordedRun(strain: Double? = 12.4, maxHr: Int? = 171, distance: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: 1_000, endTs: 3_000, sport: "Running", source: "manual", durationS: 2_000,
                   energyKcal: 402, avgHr: 148, maxHr: maxHr, strain: strain, distanceM: distance,
                   zonesJSON: nil, notes: nil, strainVersion: strain == nil ? nil : 2)
    }

    /// A session typed into the Add Workout sheet.
    private func typedSession() throws -> WorkoutRow {
        try XCTUnwrap(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSinceNow: -7_200), durationMin: 45, sport: "Yoga", avgHr: 120, energyKcal: 180))
    }

    func testARunTheAppRecordedReadsRecordedAndOneTypedInReadsManual() throws {
        XCTAssertEqual(WorkoutOrigin.of(recordedRun()), .recorded)
        XCTAssertEqual(WorkoutOrigin.of(try typedSession()), .manual)
        XCTAssertEqual(WorkoutFormat.sourceName(for: recordedRun()), String(localized: "Recorded"))
        XCTAssertEqual(WorkoutFormat.sourceName(for: try typedSession()), String(localized: "Manual"))
        XCTAssertNotEqual(String(localized: "Recorded"), String(localized: "Manual"))
    }

    func testAnyOneCaptureMarksARecordingIncludingAGpsWalkWithNoHeartRate() {
        XCTAssertEqual(WorkoutOrigin.of(recordedRun(strain: nil, maxHr: 171)), .recorded)
        XCTAssertEqual(WorkoutOrigin.of(recordedRun(strain: 9, maxHr: nil)), .recorded)
        // Heart rate not streaming: only the route's distance was captured.
        XCTAssertEqual(WorkoutOrigin.of(recordedRun(strain: nil, maxHr: nil, distance: 2_400)), .recorded)
        // An average typed by hand is not a capture.
        XCTAssertEqual(WorkoutOrigin.of(recordedRun(strain: nil, maxHr: nil, distance: nil)), .manual)
    }

    func testEditingKeepsWhatTheSessionWas() throws {
        let live = recordedRun()
        let editedLive = WorkoutSource.preservingCaptured(
            try XCTUnwrap(WorkoutSource.buildManualRow(
                start: Date(timeIntervalSince1970: 1_000), durationMin: 40, sport: "Running", avgHr: 150, energyKcal: nil,
                now: Date(timeIntervalSince1970: 10_000))), from: live)
        XCTAssertEqual(WorkoutOrigin.of(editedLive), .recorded)
        let typed = try typedSession()
        XCTAssertEqual(WorkoutOrigin.of(WorkoutSource.preservingCaptured(typed, from: typed)), .manual)
    }

    func testNothingStoredChangesAndEditingMergingAndDeletingTreatBothAlike() throws {
        let live = recordedRun()
        let typed = try typedSession()
        XCTAssertEqual(live.source, "manual")
        XCTAssertEqual(typed.source, "manual")
        XCTAssertEqual(WorkoutSource.classify(live.source), .manual)
        XCTAssertTrue(WorkoutMerge.isMergeable(live))
        XCTAssertTrue(WorkoutMerge.isMergeable(typed))
    }

    func testImportedAndDetectedRowsKeepTheirOrigins() {
        func row(_ source: String, strain: Double? = 11, maxHr: Int? = 170) -> WorkoutRow {
            WorkoutRow(startTs: 1_000, endTs: 3_000, sport: "Running", source: source, durationS: 2_000,
                       energyKcal: nil, avgHr: 140, maxHr: maxHr, strain: strain, distanceM: 5_000,
                       zonesJSON: nil, notes: nil)
        }
        XCTAssertEqual(WorkoutOrigin.of(row("whoop")), .whoop)
        XCTAssertEqual(WorkoutOrigin.of(row("apple-health")), .apple)
        XCTAssertEqual(WorkoutOrigin.of(row("apple_health")), .apple)
        XCTAssertEqual(WorkoutOrigin.of(row("my-whoop-noop")), .detected)
        XCTAssertEqual(WorkoutOrigin.of(row("lifting")), .lifting)
        XCTAssertEqual(WorkoutOrigin.of(row("activity-file")), .activityFile)
    }

    func testTheSourceFilterSplitsRecordedFromManualWithoutLosingEither() throws {
        let live = recordedRun()
        let typed = try typedSession()
        let whoop = WorkoutRow(startTs: 9_000, endTs: 10_000, sport: "Cycling", source: "whoop", durationS: 1_000,
                               energyKcal: nil, avgHr: nil, maxHr: nil, strain: 8, distanceM: nil,
                               zonesJSON: nil, notes: nil)
        let rows = [live, typed, whoop]
        XCTAssertEqual(WorkoutFilter(origin: .recorded).apply(rows), [live])
        XCTAssertEqual(WorkoutFilter(origin: .manual).apply(rows), [typed])
        XCTAssertEqual(WorkoutFilter(origin: .whoop).apply(rows), [whoop])
        XCTAssertEqual(WorkoutFilter().apply(rows), rows)
        XCTAssertTrue(WorkoutFilter(origin: .recorded).isActive)
    }
}
