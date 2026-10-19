import Foundation
import XCTest
#if canImport(NOOP)
@testable import NOOP
#else
@testable import ExperiencePolicyHarness
#endif

final class WorkoutTimelinePolicyTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testSevenCivilDaysAcrossDaylightSavingBoundary() {
        let days = WorkoutTimelinePolicy.week(items: [], through: date(2026, 3, 10), calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.component(.day, from: days.first!.day), 4)
        XCTAssertEqual(calendar.component(.day, from: days.last!.day), 10)
        XCTAssertEqual(Set(days.map(\.day)).count, 7)
    }
    func testTotalsUseKnownDurationAndCountMissingSeparately() {
        let d = date(2026, 10, 13)
        let items = [WorkoutTimelineItem(id: "a", start: d, seconds: 600),
                     WorkoutTimelineItem(id: "b", start: d, seconds: nil),
                     WorkoutTimelineItem(id: "c", start: d, seconds: .nan)]
        let day = WorkoutTimelinePolicy.week(items: items, through: d, calendar: calendar).last!
        XCTAssertEqual(day.minutes, 10)
        XCTAssertEqual(day.sessions, 3)
        XCTAssertEqual(day.missingDurations, 2)
    }
    func testGroupingUsesStartDayAndNewestFirst() {
        let items = [WorkoutTimelineItem(id: "early", start: date(2026, 10, 12, 8), seconds: 120),
                     WorkoutTimelineItem(id: "late", start: date(2026, 10, 12, 21), seconds: 120),
                     WorkoutTimelineItem(id: "new", start: date(2026, 10, 13, 0), seconds: 60)]
        let groups = WorkoutTimelinePolicy.groups(items: items, calendar: calendar)
        XCTAssertEqual(groups.map(\.ids), [["new"], ["late", "early"]])
    }
    func testGroupingKeepsEachIDOnceAndSkipsNonFiniteStarts() {
        let item = WorkoutTimelineItem(id: "same", start: date(2026, 10, 12, 8), seconds: 120)
        let items = [item, item,
                     WorkoutTimelineItem(id: "broken", start: Date(timeIntervalSinceReferenceDate: .nan), seconds: 60)]
        let groups = WorkoutTimelinePolicy.groups(items: items, calendar: calendar)
        XCTAssertEqual(groups.map(\.ids), [["same"]])
        XCTAssertEqual(groups.first?.day, calendar.startOfDay(for: date(2026, 10, 12)))
    }
    func testWeekIntervalCoversTheSameSevenDaysAsTheWeek() {
        let end = date(2026, 3, 10, 18)
        let interval = WorkoutTimelinePolicy.weekInterval(through: end, calendar: calendar)!
        let days = WorkoutTimelinePolicy.week(items: [], through: end, calendar: calendar)
        XCTAssertEqual(interval.start, days.first?.day)
        XCTAssertEqual(interval.end, calendar.startOfDay(for: date(2026, 3, 11)))
        // Mar 8 2026 is the spring-forward day in New York, so the seven days are one hour short of a full week.
        XCTAssertEqual(interval.duration, 7 * 86_400 - 3_600)
        XCTAssertNil(WorkoutTimelinePolicy.weekInterval(through: Date(timeIntervalSinceReferenceDate: .infinity),
                                                        calendar: calendar))
    }
    func testTotalsNeverReportAnUnmeasuredWeekAsZero() {
        let d = date(2026, 10, 13)
        let empty = WorkoutTimelinePolicy.totals(WorkoutTimelinePolicy.week(items: [], through: d, calendar: calendar))
        XCTAssertNil(empty.knownMinutes)
        XCTAssertEqual(empty.sessions, 0)
        let unknown = WorkoutTimelinePolicy.totals(WorkoutTimelinePolicy.week(
            items: [WorkoutTimelineItem(id: "a", start: d, seconds: nil)], through: d, calendar: calendar))
        XCTAssertNil(unknown.knownMinutes)
        XCTAssertEqual(unknown.missingDurations, 1)
        let mixed = WorkoutTimelinePolicy.totals(WorkoutTimelinePolicy.week(
            items: [WorkoutTimelineItem(id: "a", start: d, seconds: nil),
                    WorkoutTimelineItem(id: "b", start: date(2026, 10, 11), seconds: 600)],
            through: d, calendar: calendar))
        XCTAssertEqual(mixed.knownMinutes, 10)
        XCTAssertEqual(mixed.sessions, 2)
        XCTAssertEqual(mixed.missingDurations, 1)
    }
    func testFutureRowsCannotEnterTheDisplayedWeek() {
        let now = date(2026, 10, 13)
        let items = [WorkoutTimelineItem(id: "future", start: date(2026, 10, 14), seconds: 600)]
        XCTAssertEqual(WorkoutTimelinePolicy.week(items: items, through: now, calendar: calendar).reduce(0) { $0 + $1.minutes }, 0)
    }
    func testDuplicateIDsCannotDoubleCountMinutes() {
        let d = date(2026, 10, 13)
        let item = WorkoutTimelineItem(id: "same", start: d, seconds: 600)
        let days = WorkoutTimelinePolicy.week(items: [item, item], through: d, calendar: calendar)
        XCTAssertEqual(days.last?.sessions, 1)
        XCTAssertEqual(days.last?.minutes, 10)
    }
    func testNegativeDurationIsMissingAndRecordedZeroIsKnown() {
        let d = date(2026, 10, 13)
        let items = [WorkoutTimelineItem(id: "zero", start: d, seconds: 0),
                     WorkoutTimelineItem(id: "negative", start: d, seconds: -5)]
        let result = WorkoutTimelinePolicy.week(items: items, through: d, calendar: calendar).last!
        XCTAssertEqual(result.minutes, 0)
        XCTAssertEqual(result.missingDurations, 1)
    }
}
