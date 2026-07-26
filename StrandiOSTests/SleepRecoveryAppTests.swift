import XCTest
@testable import NOOP
import WhoopStore

final class SleepRecoveryAppTests: XCTestCase {
    private func sleep(
        start: Int,
        end: Int,
        edited: Bool,
        restingHr: Int?,
        avgHrv: Double?
    ) -> CachedSleepSession {
        CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: 0.85,
            restingHr: restingHr,
            avgHrv: avgHrv,
            stagesJSON: nil,
            userEdited: edited,
            startTsAdjusted: nil)
    }

    func testTwinlessRecoveredNightBackfillsDailyVitals() {
        let recovered = sleep(
            start: 1_000,
            end: 5_000,
            edited: true,
            restingHr: 49,
            avgHrv: 64)

        let folded = SleepEditVitalFold.fold(
            detected: [],
            edits: [recovered],
            fallbackRestingHr: nil,
            fallbackAvgHrv: nil)

        XCTAssertTrue(folded.didApply)
        XCTAssertEqual(folded.restingHr, 49)
        XCTAssertEqual(folded.avgHrv, 64)
    }

    func testEditedTwinReplacesDetectedVitals() {
        let detected = sleep(
            start: 1_000,
            end: 5_000,
            edited: false,
            restingHr: 58,
            avgHrv: 42)
        let edited = sleep(
            start: 1_000,
            end: 4_800,
            edited: true,
            restingHr: 51,
            avgHrv: 61)

        let folded = SleepEditVitalFold.fold(
            detected: [detected],
            edits: [edited],
            fallbackRestingHr: 58,
            fallbackAvgHrv: 42)

        XCTAssertTrue(folded.didApply)
        XCTAssertEqual(folded.restingHr, 51)
        XCTAssertEqual(folded.avgHrv, 61)
    }

    func testSeveralRecoveredBlocksUseLowestRHRAndDurationWeightedHRV() {
        let first = sleep(
            start: 0,
            end: 3_600,
            edited: true,
            restingHr: 54,
            avgHrv: 40)
        let second = sleep(
            start: 3_600,
            end: 10_800,
            edited: true,
            restingHr: 48,
            avgHrv: 70)

        let folded = SleepEditVitalFold.fold(
            detected: [],
            edits: [first, second],
            fallbackRestingHr: nil,
            fallbackAvgHrv: nil)

        XCTAssertEqual(folded.restingHr, 48)
        XCTAssertEqual(folded.avgHrv ?? 0, 60, accuracy: 0.0001)
    }

    func testOrdinaryStageOnlyEditDoesNotPerturbDailyVitals() {
        let edit = sleep(
            start: 1_000,
            end: 5_000,
            edited: true,
            restingHr: nil,
            avgHrv: nil)

        let folded = SleepEditVitalFold.fold(
            detected: [],
            edits: [edit],
            fallbackRestingHr: 52,
            fallbackAvgHrv: 58)

        XCTAssertFalse(folded.didApply)
        XCTAssertEqual(folded.restingHr, 52)
        XCTAssertEqual(folded.avgHrv, 58)
    }

    func testDefaultMissedSleepSeedIsEightHoursAndNeverFutureDated() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 26, hour: 12, minute: 30)))

        let seed = MissedSleepWindowSeed.lastNight(now: now, calendar: calendar)

        XCTAssertEqual(seed.end.timeIntervalSince(seed.start), 8 * 3_600, accuracy: 1)
        XCTAssertLessThanOrEqual(seed.end, now)
        XCTAssertEqual(calendar.component(.hour, from: seed.end), 9)
    }
}
