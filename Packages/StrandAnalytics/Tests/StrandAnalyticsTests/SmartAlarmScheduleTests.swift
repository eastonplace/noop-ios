import XCTest
@testable import StrandAnalytics

final class SmartAlarmScheduleTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    func testEveryDayUsesTodayThenTomorrow() throws {
        let cal = calendar("UTC")
        let morning = date(2026, 7, 22, 6, 0, calendar: cal)
        let evening = date(2026, 7, 22, 20, 0, calendar: cal)
        XCTAssertTrue(cal.isDate(try XCTUnwrap(SmartAlarmSchedule.nextDate(
            minutes: 7 * 60, weekdays: [], after: morning, calendar: cal)), inSameDayAs: morning))
        let tomorrow = try XCTUnwrap(SmartAlarmSchedule.nextDate(
            minutes: 7 * 60, weekdays: [], after: evening, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: tomorrow), 23)
    }

    func testSingleWeekdaySeveralDaysAwayAndPassedToday() throws {
        let cal = calendar("UTC")
        let friday = date(2026, 7, 24, 20, 0, calendar: cal)
        let monday = try XCTUnwrap(SmartAlarmSchedule.nextDate(
            minutes: 7 * 60, weekdays: [2], after: friday, calendar: cal))
        XCTAssertEqual(cal.component(.weekday, from: monday), 2)

        let mondayAfter = date(2026, 7, 27, 8, 0, calendar: cal)
        let nextMonday = try XCTUnwrap(SmartAlarmSchedule.nextDate(
            minutes: 7 * 60, weekdays: [2], after: mondayAfter, calendar: cal))
        XCTAssertEqual(cal.dateComponents([.day], from: cal.startOfDay(for: mondayAfter),
                                          to: cal.startOfDay(for: nextMonday)).day, 7)
    }

    func testDSTSpringAndFallKeepLocalWakeHour() throws {
        let cal = calendar()
        for now in [date(2026, 3, 7, 20, 0, calendar: cal),
                    date(2026, 10, 31, 20, 0, calendar: cal)] {
            let next = try XCTUnwrap(SmartAlarmSchedule.nextDate(
                minutes: 7 * 60, weekdays: [], after: now, calendar: cal))
            XCTAssertEqual(cal.component(.hour, from: next), 7)
            XCTAssertEqual(cal.component(.minute, from: next), 0)
        }
    }
}
