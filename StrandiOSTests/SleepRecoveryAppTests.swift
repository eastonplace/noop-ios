import XCTest
@testable import NOOP

final class SleepRecoveryAppTests: XCTestCase {
    func testOnlySleepEmptyStateRoutesToRecoveryCard() {
        XCTAssertTrue(MissedSleepRecoveryRouting.shouldReplaceEmptyState(
            "No nights here yet. Import your WHOOP export to see sleep."))
        XCTAssertFalse(MissedSleepRecoveryRouting.shouldReplaceEmptyState(
            "No workouts here yet."))
        XCTAssertFalse(MissedSleepRecoveryRouting.shouldReplaceEmptyState(
            "No nights stored for the selected range."))
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

    func testEarlyMorningSeedEndsAtNowInsteadOfFutureNineAM() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 26, hour: 6, minute: 15)))

        let seed = MissedSleepWindowSeed.lastNight(now: now, calendar: calendar)

        XCTAssertEqual(seed.end.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(seed.end.timeIntervalSince(seed.start), 8 * 3_600, accuracy: 1)
    }

    func testOnlyCompleteAndPartialOutcomesDismissTheEditor() {
        let complete = MissedSleepRecoverySaveResult(
            status: .complete, title: "", message: "", confidence: 0.9,
            sessionStart: 1, sessionEnd: 2)
        let partial = MissedSleepRecoverySaveResult(
            status: .partial, title: "", message: "", confidence: 0.5,
            sessionStart: 1, sessionEnd: 2)
        let insufficient = MissedSleepRecoverySaveResult(
            status: .insufficientData, title: "", message: "", confidence: 0,
            sessionStart: nil, sessionEnd: nil)
        let conflict = MissedSleepRecoverySaveResult(
            status: .overlapConflict, title: "", message: "", confidence: 0.8,
            sessionStart: nil, sessionEnd: nil)

        XCTAssertTrue(complete.savedSession)
        XCTAssertTrue(partial.savedSession)
        XCTAssertFalse(insufficient.savedSession)
        XCTAssertFalse(conflict.savedSession)
    }
}
