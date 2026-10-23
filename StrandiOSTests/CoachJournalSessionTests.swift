import Foundation
import XCTest
#if !COACH_JOURNAL_SESSION_STANDALONE_TESTS
@testable import NOOP
#endif

/// These test the same value-only gate the live session uses after every awaited snapshot.
final class CoachJournalSessionTests: XCTestCase {
    private let day = "2026-10-22"

    func testSnapshotRequiresTheSelectedDayAndSource() throws {
        var gate = CoachJournalRequestGate()
        gate.configure(day: day, sourceContext: "source-a", canRead: true)
        let request = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.accepts(request, day: day, sourceContext: "source-a"))
        XCTAssertFalse(gate.accepts(request, day: "2026-10-21", sourceContext: "source-a"))
        XCTAssertFalse(gate.accepts(request, day: day, sourceContext: "source-b"))
    }

    func testDaySelectionRejectsThePreviousAwaitedSnapshot() throws {
        var gate = CoachJournalRequestGate()
        gate.configure(day: day, sourceContext: "source-a", canRead: true)
        let previous = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.configure(day: "2026-10-21", sourceContext: "source-a", canRead: true))
        XCTAssertFalse(gate.accepts(previous, day: day, sourceContext: "source-a"))
        let selected = try XCTUnwrap(gate.begin())
        XCTAssertEqual(selected.day, "2026-10-21")
    }

    func testSourceReplacementRejectsThePreviousAwaitedSnapshot() throws {
        var gate = CoachJournalRequestGate()
        gate.configure(day: day, sourceContext: "database-a", canRead: true)
        let previous = try XCTUnwrap(gate.begin())
        gate.configure(day: day, sourceContext: "database-b", canRead: true)
        XCTAssertFalse(gate.accepts(previous, day: day, sourceContext: "database-a"))
    }

    func testAReplacementRequestRejectsAnEarlierCompletionForTheSameDay() throws {
        var gate = CoachJournalRequestGate()
        gate.configure(day: day, sourceContext: "source-a", canRead: true)
        let previous = try XCTUnwrap(gate.begin())
        let current = try XCTUnwrap(gate.begin())
        XCTAssertFalse(gate.accepts(previous, day: day, sourceContext: "source-a"))
        XCTAssertTrue(gate.accepts(current, day: day, sourceContext: "source-a"))
    }

    func testRevokingAndRestoringConsentDoesNotResurrectAnOldRequest() throws {
        var gate = CoachJournalRequestGate()
        gate.configure(day: day, sourceContext: "source-a", canRead: true)
        let previous = try XCTUnwrap(gate.begin())
        gate.configure(day: day, sourceContext: "source-a", canRead: false)
        XCTAssertNil(gate.begin())
        gate.configure(day: day, sourceContext: "source-a", canRead: true)
        XCTAssertFalse(gate.accepts(previous, day: day, sourceContext: "source-a"))
    }

    func testUnrelatedPublicationsDoNotInvalidateTheActiveRequest() throws {
        var gate = CoachJournalRequestGate()
        gate.configure(day: day, sourceContext: "source-a", canRead: true)
        let current = try XCTUnwrap(gate.begin())
        XCTAssertFalse(gate.configure(day: day, sourceContext: "source-a", canRead: true))
        XCTAssertTrue(gate.accepts(current, day: day, sourceContext: "source-a"))
    }

    func testManualJournalRoutesToReviewWithoutModelAvailabilityOrConsent() {
        let access = CoachJournalAccessPolicy(coachEnabled: false, usesPersonalData: false,
                                              isPreview: false, hasRepository: true, sourceFenced: false)
        XCTAssertFalse(access.canReadAutomatically)
        XCTAssertTrue(access.canUseManualJournal)
        XCTAssertEqual(CoachComposerRouting.destination(mode: .journal, access: access, modelAvailable: false),
                       .journalReview)
        XCTAssertEqual(CoachComposerRouting.destination(mode: .coach, access: access, modelAvailable: false),
                       .blocked)
    }

    func testAutomaticReadsRequireBothEnabledAndPersonalRecordConsent() {
        for enabled in [false, true] {
            for consent in [false, true] {
                let access = CoachJournalAccessPolicy(coachEnabled: enabled, usesPersonalData: consent,
                                                      isPreview: false, hasRepository: true, sourceFenced: false)
                XCTAssertEqual(access.canReadAutomatically, enabled && consent)
            }
        }
    }

    func testPreviewCannotReadOrRouteToAWriteEvenIfARepositoryWasAccidentallyProvided() {
        let access = CoachJournalAccessPolicy(coachEnabled: true, usesPersonalData: true,
                                              isPreview: true, hasRepository: true, sourceFenced: false)
        XCTAssertFalse(access.canReadAutomatically)
        XCTAssertFalse(access.canUseManualJournal)
        XCTAssertEqual(CoachComposerRouting.destination(mode: .journal, access: access, modelAvailable: true), .blocked)
        XCTAssertEqual(CoachComposerRouting.destination(mode: .coach, access: access, modelAvailable: true), .blocked)
    }

    func testMissingRepositoryAndFencedSourceCannotOpenManualJournal() {
        let missing = CoachJournalAccessPolicy(coachEnabled: true, usesPersonalData: true,
                                               isPreview: false, hasRepository: false, sourceFenced: false)
        let fenced = CoachJournalAccessPolicy(coachEnabled: true, usesPersonalData: true,
                                              isPreview: false, hasRepository: true, sourceFenced: true)
        for access in [missing, fenced] {
            XCTAssertFalse(access.canReadAutomatically)
            XCTAssertFalse(access.canUseManualJournal)
            XCTAssertEqual(CoachComposerRouting.destination(mode: .journal, access: access, modelAvailable: true), .blocked)
        }
    }

    func testDayPillOffsetsUseCivilDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T09:30:00Z"))
        XCTAssertEqual(CoachJournalDaySelection.key(dayOffset: 0, now: now, calendar: calendar), "2026-11-01")
        XCTAssertEqual(CoachJournalDaySelection.key(dayOffset: 1, now: now, calendar: calendar), "2026-10-31")
        XCTAssertEqual(CoachJournalDaySelection.key(dayOffset: -1, now: now, calendar: calendar), "2026-11-02")
        XCTAssertEqual(CoachJournalDaySelection.offset(for: "2026-10-31", now: now, calendar: calendar), 1)
    }

    func testSelectedWakeDayStaysPinnedAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let before = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T23:59:00Z"))
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T00:01:00Z"))
        let selected = "2026-10-22"
        XCTAssertEqual(CoachJournalDaySelection.offset(for: selected, now: before, calendar: calendar), 0)
        XCTAssertEqual(CoachJournalDaySelection.offset(for: selected, now: after, calendar: calendar), 1)
        XCTAssertEqual(selected, "2026-10-22")
    }

    func testInvalidCivilDayDoesNotBecomeToday() {
        XCTAssertNil(CoachJournalDaySelection.date(for: "2026-02-30"))
        XCTAssertNil(CoachJournalDaySelection.date(for: "tomorrow"))
        XCTAssertNil(CoachJournalDaySelection.offset(for: "2026-02-30"))
    }
}

#if COACH_JOURNAL_SESSION_STANDALONE_TESTS
@main
enum CoachJournalSessionTestMain {
    static func main() {
        XCTMain([testCase([
            ("testSnapshotRequiresTheSelectedDayAndSource", CoachJournalSessionTests.testSnapshotRequiresTheSelectedDayAndSource),
            ("testDaySelectionRejectsThePreviousAwaitedSnapshot", CoachJournalSessionTests.testDaySelectionRejectsThePreviousAwaitedSnapshot),
            ("testSourceReplacementRejectsThePreviousAwaitedSnapshot", CoachJournalSessionTests.testSourceReplacementRejectsThePreviousAwaitedSnapshot),
            ("testAReplacementRequestRejectsAnEarlierCompletionForTheSameDay", CoachJournalSessionTests.testAReplacementRequestRejectsAnEarlierCompletionForTheSameDay),
            ("testRevokingAndRestoringConsentDoesNotResurrectAnOldRequest", CoachJournalSessionTests.testRevokingAndRestoringConsentDoesNotResurrectAnOldRequest),
            ("testUnrelatedPublicationsDoNotInvalidateTheActiveRequest", CoachJournalSessionTests.testUnrelatedPublicationsDoNotInvalidateTheActiveRequest),
            ("testManualJournalRoutesToReviewWithoutModelAvailabilityOrConsent", CoachJournalSessionTests.testManualJournalRoutesToReviewWithoutModelAvailabilityOrConsent),
            ("testAutomaticReadsRequireBothEnabledAndPersonalRecordConsent", CoachJournalSessionTests.testAutomaticReadsRequireBothEnabledAndPersonalRecordConsent),
            ("testPreviewCannotReadOrRouteToAWriteEvenIfARepositoryWasAccidentallyProvided", CoachJournalSessionTests.testPreviewCannotReadOrRouteToAWriteEvenIfARepositoryWasAccidentallyProvided),
            ("testMissingRepositoryAndFencedSourceCannotOpenManualJournal", CoachJournalSessionTests.testMissingRepositoryAndFencedSourceCannotOpenManualJournal),
            ("testDayPillOffsetsUseCivilDaysAcrossDaylightSaving", CoachJournalSessionTests.testDayPillOffsetsUseCivilDaysAcrossDaylightSaving),
            ("testSelectedWakeDayStaysPinnedAcrossMidnight", CoachJournalSessionTests.testSelectedWakeDayStaysPinnedAcrossMidnight),
            ("testInvalidCivilDayDoesNotBecomeToday", CoachJournalSessionTests.testInvalidCivilDayDoesNotBecomeToday)
        ])])
    }
}
#endif
