import Foundation
import XCTest
#if canImport(NOOP)
@testable import NOOP
#else
@testable import ExperiencePolicyHarness
#endif

final class CoachExperiencePolicyTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 1_792_008_000) }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testGeneralEducationDoesNotPlanPersonalRead() {
        let plan = CoachEvidencePolicy.plan(for: "What does HRV mean?", now: now, calendar: calendar)
        XCTAssertEqual(plan, .general)
    }

    func testPersonalWorkoutRequestPlansOneBoundedRead() {
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "Show my recent workouts", now: now, calendar: calendar),
                       .read(tool: "workout_history", days: 14))
    }

    func testRecoveryComparisonIncludesLastCalendarWeekAndThisWeek() {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        let first = calendar.date(byAdding: .day, value: -7, to: week.start)!
        let count = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day! + 1
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "Compare my recovery with last week", now: now, calendar: calendar),
                       .read(tool: "metric_trends", days: count))
    }

    func testExplicitSupportedWindowIsPreserved() {
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "Show my sleep for 21 days", now: now, calendar: calendar),
                       .read(tool: "sleep_history", days: 21))
    }

    func testLongWindowIsNeverSilentlyClamped() {
        for question in ["Show my sleep over 90 days", "Review my training this year", "Show my last 6 weeks of workouts"] {
            guard case .needsNarrowerRange = CoachEvidencePolicy.plan(for: question, now: now, calendar: calendar) else {
                return XCTFail("An unsupported window must stay explicit: \(question)")
            }
        }
    }

    func testDateRangeSpanningMoreThanThirtyOneDaysIsRejected() {
        let question = "Show my sleep from 2026-08-01 to 2026-10-01"
        guard case .needsNarrowerRange = CoachEvidencePolicy.plan(for: question, now: now, calendar: calendar) else {
            return XCTFail("The date range must not fall back to a recent default")
        }
    }

    func testGeneralQuestionWithYearDoesNotBecomePersonal() {
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "What is a training year?", now: now, calendar: calendar), .general)
    }

    func testDailyOutlookHasCurrentDayEvidence() {
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "Give me my daily outlook using my latest available records. Help me plan today.",
                                               now: now, calendar: calendar), .read(tool: "current_day", days: 1))
    }

    func testConsentControlsWhetherPlannedReadCanExecute() {
        XCTAssertFalse(CoachEvidencePolicy.permitsPersonalRead(consent: false, recordsUpdating: false))
        XCTAssertFalse(CoachEvidencePolicy.permitsPersonalRead(consent: true, recordsUpdating: true))
        XCTAssertTrue(CoachEvidencePolicy.permitsPersonalRead(consent: true, recordsUpdating: false))
    }

    func testProgressRejectsEventsFromAnEarlierOperation() {
        var state = CoachResponseProgress()
        let old = UUID(), current = UUID()
        state.begin(old)
        state.begin(current)
        XCTAssertFalse(state.advance(.reading(tool: "sleep_history", days: 14), operation: old))
        XCTAssertEqual(state.stage, .preparing)
        XCTAssertTrue(state.advance(.reading(tool: "workout_history", days: 7), operation: current))
        XCTAssertEqual(state.stage, .reading(tool: "workout_history", days: 7))
    }

    func testTerminalProgressRejectsLateChunks() {
        var state = CoachResponseProgress()
        let id = UUID()
        state.begin(id)
        XCTAssertTrue(state.advance(.stopped, operation: id))
        XCTAssertFalse(state.advance(.writing, operation: id))
        XCTAssertEqual(state.stage, .stopped)
    }

    func testNoOpProgressDoesNotPublishAnotherAnnouncement() {
        var state = CoachResponseProgress()
        let id = UUID()
        state.begin(id)
        XCTAssertTrue(state.advance(.writing, operation: id))
        XCTAssertFalse(state.advance(.writing, operation: id))
    }

    func testToolLabelsDescribeObservedWork() {
        XCTAssertEqual(CoachResponseStage.reading(tool: "workout_history", days: 7).title, "Reading workout history")
        XCTAssertEqual(CoachResponseStage.reading(tool: "sleep_history", days: 14).detail, "Requested window: 14 days")
        XCTAssertFalse(CoachResponseStage.writing.title.contains("Thinking"))
        XCTAssertFalse(CoachResponseStage.complete.isActive)
    }

    func testContentGrowthDoesNotInterruptFollowAtBottom() {
        var policy = CoachScrollPolicy()
        policy.observe(distanceFromBottom: 180, userIsDragging: false)
        XCTAssertTrue(policy.followsLatest)
    }

    func testScrollingIntoHistoryStopsFollowAndJumpRestoresIt() {
        var policy = CoachScrollPolicy()
        policy.observe(distanceFromBottom: 200, userIsDragging: true)
        XCTAssertFalse(policy.followsLatest)
        policy.jumpToLatest()
        XCTAssertTrue(policy.followsLatest)
    }

    func testManualReturnToBottomResumesFollow() {
        var policy = CoachScrollPolicy()
        policy.observe(distanceFromBottom: 200, userIsDragging: true)
        policy.observe(distanceFromBottom: 20, userIsDragging: true)
        XCTAssertTrue(policy.followsLatest)
    }

    func testUnsupportedDatesDoNotPretendToBeRecentRecords() {
        guard case .needsNarrowerRange = CoachEvidencePolicy.plan(for: "Show my sleep from 2026-02-30", now: now, calendar: calendar) else {
            return XCTFail("Invalid explicit dates must be handled before a read")
        }
    }
    func testWorkoutCaloriesStayWithWorkoutRecords() {
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "Show my workout calories", now: now, calendar: calendar),
                       .read(tool: "workout_history", days: 14))
    }

    func testTellMeGeneralExplanationDoesNotReadRecords() {
        XCTAssertEqual(CoachEvidencePolicy.plan(for: "Tell me what HRV means", now: now, calendar: calendar), .general)
    }

    func testYesterdayQueryPinsTheActualDayBeforeQuestionText() {
        let question = "Show my workouts yesterday"
        let query = CoachEvidencePolicy.readQuery(for: question, days: 1, now: now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(query.hasPrefix(f.string(from: yesterday)))
    }

    func testExplicitDatesAppearOnlyOnceInNormalizedQuery() {
        let query = CoachEvidencePolicy.readQuery(for: "Compare my sleep from 2026-10-01 to 2026-10-07", days: 7,
                                                 now: now, calendar: calendar)
        XCTAssertTrue(query.hasPrefix("2026-10-01 through 2026-10-07"))
        XCTAssertEqual(query.components(separatedBy: "2026-10-01").count, 2)
        XCTAssertEqual(query.components(separatedBy: "2026-10-07").count, 2)
    }

    func testEmptyEvidenceProgressDoesNotClaimMeasurementsExist() {
        XCTAssertEqual(CoachResponseStage.evidenceReady.title, "Record check complete")
    }

    func testLastNightUsesTheWakeDayRecord() {
        let question = "Show my sleep last night"
        XCTAssertEqual(CoachEvidencePolicy.plan(for: question, now: now, calendar: calendar),
                       .read(tool: "sleep_history", days: 1))
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(CoachEvidencePolicy.readQuery(for: question, days: 1, now: now, calendar: calendar)
            .hasPrefix(f.string(from: now)))
    }

    func testLastWeekPinsPreviousCalendarWeek() {
        let question = "Show my workouts last week"
        let query = CoachEvidencePolicy.readQuery(for: question, days: 7, now: now, calendar: calendar)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
        let previousStart = calendar.date(byAdding: .day, value: -7, to: thisWeek.start)!
        let previousEnd = calendar.date(byAdding: .day, value: -1, to: thisWeek.start)!
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(query.hasPrefix(f.string(from: previousStart) + " through " + f.string(from: previousEnd)))
    }

    func testLastMonthUsesActualCalendarLength() {
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!
        let question = "Show my workouts last month"
        XCTAssertEqual(CoachEvidencePolicy.plan(for: question, now: fixedNow, calendar: calendar),
                       .read(tool: "workout_history", days: 28))
        XCTAssertTrue(CoachEvidencePolicy.readQuery(for: question, days: 28, now: fixedNow, calendar: calendar)
            .hasPrefix("2026-02-01 through 2026-02-28"))
    }

}
