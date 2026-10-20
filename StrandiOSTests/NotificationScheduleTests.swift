import XCTest
import StrandAnalytics
@testable import NOOP

final class NotificationScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    func testSpringGapMovesToFirstValidMinute() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let result = try XCTUnwrap(NotificationSchedulePlanner.resolve(day: day, minute: 150, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: result), 3)
        XCTAssertEqual(calendar.component(.minute, from: result), 0)
    }
    func testFallRepeatedMinuteUsesFirstOccurrence() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let result = try XCTUnwrap(NotificationSchedulePlanner.resolve(day: day, minute: 90, calendar: calendar))
        XCTAssertEqual(calendar.timeZone.secondsFromGMT(for: result), -14400)
    }
    func testDateOnlyAndCompletedPlansAreNotReminders() {
        XCTAssertFalse(NotificationSchedulePlanner.shouldScheduleWorkout(hasExplicitTime: false, completedSessionID: nil))
        XCTAssertFalse(NotificationSchedulePlanner.shouldScheduleWorkout(hasExplicitTime: true, completedSessionID: "saved"))
        XCTAssertTrue(NotificationSchedulePlanner.shouldScheduleWorkout(hasExplicitTime: true, completedSessionID: nil))
    }
    func testWorkoutExpiryUsesChosenStartRatherThanReminderLeadAndJournalUsesTwoHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(3600)
        let reminder = NotificationSchedulePlanner.candidate(group: .workoutPlan, id: "plan",
            scheduledAt: start.addingTimeInterval(-1800), source: "source",
            destination: .plannedWorkout(id: "plan"), now: now, actionAt: start)
        XCTAssertEqual(reminder.expiresAt, start.addingTimeInterval(7200))
        XCTAssertNotEqual(reminder.expiresAt, reminder.scheduledAt?.addingTimeInterval(7200))
        let journal = NotificationSchedulePlanner.candidate(group: .journalCheckIn, id: "day",
            scheduledAt: start, source: "source", destination: .journal(logicalDay: "day"), now: now)
        XCTAssertEqual(journal.expiresAt, start.addingTimeInterval(7200))
        for candidate in [reminder, journal] {
            let result = NotificationPolicy.evaluate(candidates: [candidate],
                preferences: .init(modes: [candidate.group: .notify]),
                context: .init(sourceContext: "source", logicalDay: "day"), history: [], now: candidate.expiresAt)
            XCTAssertEqual(result.decisions.first?.reason, .expired)
            XCTAssertTrue(result.selected.isEmpty)
        }
    }
    func testRecurringIdentitySurvivesNextWeekAndNewIntentGetsNewIdentity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func occurrence(_ scheduled: Date, revision: Int) -> NotificationCandidate {
            NotificationSchedulePlanner.candidate(group: .weeklyReview, id: "1:1080:UTC", scheduledAt: scheduled,
                source: "source", destination: .weeklyReview(weekStart: "2027-01-01"), now: now,
                revision: revision, recurring: true)
        }
        let first = occurrence(now.addingTimeInterval(3600), revision: 1)
        let next = occurrence(now.addingTimeInterval(7 * 86400), revision: 1)
        let reenabled = occurrence(now.addingTimeInterval(3600), revision: 2)
        XCTAssertEqual(first.occurrenceID, next.occurrenceID)
        XCTAssertNotEqual(first.occurrenceID, reenabled.occurrenceID)
        XCTAssertEqual(first.expiresAt, .distantFuture)
    }

    func testCompletedReviewWeekStartsMondayRegardlessOfLocaleFirstWeekday() throws {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        XCTAssertEqual(NotificationSchedulePlanner.previousCompleteWeekStart(now: tuesday, calendar: sundayFirst), expected)
        XCTAssertEqual(NotificationSchedulePlanner.previousCompleteWeekStart(now: tuesday, calendar: mondayFirst), expected)
    }

}
