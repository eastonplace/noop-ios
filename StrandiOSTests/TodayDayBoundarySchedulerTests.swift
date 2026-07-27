import XCTest
@testable import NOOP

final class TodayDayBoundarySchedulerTests: XCTestCase {
    private func newYorkCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second)))
    }

    func testBeforeMidnightSchedulesLocalMidnight() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27, hour: 23, minute: 59)
        let expected = try date(calendar, year: 2026, month: 7, day: 28, hour: 0)

        XCTAssertEqual(
            TodayDayBoundaryScheduler.nextBoundary(after: now, calendar: calendar),
            expected)
    }

    func testAfterMidnightBeforeRolloverSchedulesFourAM() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 28, hour: 0, minute: 30)
        let expected = try date(calendar, year: 2026, month: 7, day: 28, hour: 4)

        XCTAssertEqual(
            TodayDayBoundaryScheduler.nextBoundary(after: now, calendar: calendar),
            expected)
    }

    func testAtOrAfterFourAMSchedulesNextMidnight() throws {
        let calendar = try newYorkCalendar()
        let exactlyFour = try date(calendar, year: 2026, month: 7, day: 28, hour: 4)
        let afterFour = try date(calendar, year: 2026, month: 7, day: 28, hour: 12)
        let expected = try date(calendar, year: 2026, month: 7, day: 29, hour: 0)

        XCTAssertEqual(
            TodayDayBoundaryScheduler.nextBoundary(after: exactlyFour, calendar: calendar),
            expected)
        XCTAssertEqual(
            TodayDayBoundaryScheduler.nextBoundary(after: afterFour, calendar: calendar),
            expected)
    }

    func testSpringDSTDayStillSchedulesLocalFourAM() throws {
        let calendar = try newYorkCalendar()
        // New York skips 02:00 on March 8, 2026. Calendar arithmetic must still target the real local 04:00.
        let now = try date(calendar, year: 2026, month: 3, day: 8, hour: 0, minute: 30)
        let boundary = TodayDayBoundaryScheduler.nextBoundary(after: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: boundary)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 8)
        XCTAssertEqual(components.hour, 4)
        XCTAssertEqual(components.minute, 0)
    }

    func testFallDSTDayStillSchedulesLocalFourAM() throws {
        let calendar = try newYorkCalendar()
        // New York repeats 01:00 on November 1, 2026; 04:00 remains the unambiguous logical rollover.
        let now = try date(calendar, year: 2026, month: 11, day: 1, hour: 0, minute: 30)
        let boundary = TodayDayBoundaryScheduler.nextBoundary(after: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: boundary)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 4)
        XCTAssertEqual(components.minute, 0)
    }

    func testTodayLoadKeyChangesWhenOnlyPresentationDayChanges() {
        let before = TodayLoadKey(seq: 42, offset: 0, presentationDay: "2026-07-27|2026-07-27|2026-07-27")
        let afterMidnight = TodayLoadKey(seq: 42, offset: 0, presentationDay: "2026-07-28|2026-07-28|2026-07-28")
        let afterLogicalRollover = TodayLoadKey(seq: 42, offset: 0, presentationDay: "2026-07-28|2026-07-28|2026-07-27")

        XCTAssertNotEqual(before, afterMidnight)
        XCTAssertNotEqual(afterMidnight, afterLogicalRollover)
    }
}
