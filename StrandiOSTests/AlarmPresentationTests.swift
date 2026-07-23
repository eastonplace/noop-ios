import XCTest
import StrandAnalytics
@testable import NOOP

final class AlarmPresentationTests: XCTestCase {
    func testSpringForwardPresentationUsesEndpointClockAndRealElapsedTime() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 3, 7, 23, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [1],
            calendar: calendar
        ))

        XCTAssertEqual(presentation.remainingMinutes, 7 * 60)
        XCTAssertEqual(presentation.wakeAxisMinutes - presentation.nowAxisMinutes, 7 * 60)
        XCTAssertEqual(presentation.wakeAxisMinutes.moduloDay, 7 * 60)
        XCTAssertEqual(presentation.wakeClock(locale: Locale(identifier: "en_US"), calendar: calendar), "7:00 AM")
        XCTAssertEqual(presentation.dayLabel, "Tomorrow")
        XCTAssertTrue(presentation.isUpcomingSleepPeriod)
    }

    func testSpringForwardPlanClocksMapBackToRealDates() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 3, 7, 23, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [1],
            calendar: calendar
        ))
        let asleepBy = presentation.wakeAxisMinutes - 8 * 60

        XCTAssertEqual(
            presentation.clockLabel(
                for: presentation.nowAxisMinutes,
                locale: Locale(identifier: "en_US"),
                calendar: calendar
            ),
            "11:00 PM"
        )
        XCTAssertEqual(
            presentation.clockLabel(
                for: asleepBy,
                locale: Locale(identifier: "en_US"),
                calendar: calendar
            ),
            "10:00 PM"
        )
    }

    func testFallBackPresentationUsesEndpointClockAndRealElapsedTime() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 10, 31, 23, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [1],
            calendar: calendar
        ))

        XCTAssertEqual(presentation.remainingMinutes, 9 * 60)
        XCTAssertEqual(presentation.wakeAxisMinutes - presentation.nowAxisMinutes, 9 * 60)
        XCTAssertEqual(presentation.wakeAxisMinutes.moduloDay, 7 * 60)
        XCTAssertEqual(presentation.wakeClock(locale: Locale(identifier: "en_US"), calendar: calendar), "7:00 AM")
        XCTAssertEqual(presentation.dayLabel, "Tomorrow")
    }

    func testFallBackPlanClocksMapBackToRealDates() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 10, 31, 23, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [1],
            calendar: calendar
        ))
        let asleepBy = presentation.wakeAxisMinutes - 8 * 60

        XCTAssertEqual(
            presentation.clockLabel(
                for: presentation.nowAxisMinutes,
                locale: Locale(identifier: "en_US"),
                calendar: calendar
            ),
            "11:00 PM"
        )
        XCTAssertEqual(
            presentation.clockLabel(
                for: asleepBy,
                locale: Locale(identifier: "en_US"),
                calendar: calendar
            ),
            "12:00 AM"
        )
    }

    func testSameDayAlarmKeepsTodayIdentity() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 7, 27, 1, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [2],
            calendar: calendar
        ))

        XCTAssertEqual(presentation.remainingMinutes, 6 * 60)
        XCTAssertEqual(presentation.dayLabel, "Today")
        XCTAssertEqual(presentation.wakeAxisMinutes, 7 * 60)
        XCTAssertEqual(presentation.nowAxisMinutes, 60)
    }

    func testTomorrowAlarmKeepsTomorrowIdentity() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 7, 27, 23, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [3],
            calendar: calendar
        ))

        XCTAssertEqual(presentation.remainingMinutes, 8 * 60)
        XCTAssertEqual(presentation.dayLabel, "Tomorrow")
        XCTAssertEqual(presentation.wakeAxisMinutes.moduloDay, 7 * 60)
    }

    func testWeekdaySeveralDaysAwayUsesCalendarDayIdentity() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 7, 22, 12, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [2],
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        ))
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: presentation.endpoint)
        let civilDays = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: presentation.endpoint)
        ).day

        XCTAssertEqual(civilDays, 5)
        XCTAssertEqual(components.weekday, 2)
        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(presentation.dayLabel, "Monday, Jul 27")
        XCTAssertFalse(presentation.isUpcomingSleepPeriod)
    }

    func testMidnightBoundaryNudgeStaysWithinRecurringOccurrence() {
        let monday0002 = 1_440 + 2
        XCTAssertNil(SleepAlarmEditorSupport.sameOccurrenceMinute(
            current: monday0002,
            proposed: monday0002 - 5
        ))
        XCTAssertEqual(SleepAlarmEditorSupport.sameOccurrenceMinute(
            current: monday0002 + 10,
            proposed: monday0002 + 5
        ), monday0002 + 5)

        let sunday2358 = 1_438
        XCTAssertNil(SleepAlarmEditorSupport.sameOccurrenceMinute(
            current: sunday2358,
            proposed: sunday2358 + 5
        ))
    }

    func testVoiceOverWakeTimeValueUsesEndpointClock() throws {
        let calendar = newYorkCalendar()
        let now = try date(2026, 3, 7, 23, 0, calendar: calendar)
        let presentation = try XCTUnwrap(SleepAlarmEditorSupport.schedule(
            at: now,
            minutes: 7 * 60,
            weekdays: [1],
            calendar: calendar
        ))

        XCTAssertEqual(
            presentation.voiceOverWakeTimeValue(
                locale: Locale(identifier: "en_US"),
                calendar: calendar
            ),
            "Wake time 7:00 AM, Tomorrow"
        )
    }

    func testFallBackNudgeRejectsCrossingRepeatedHourOccurrence() throws {
        let calendar = newYorkCalendar()
        let firstOneFiftyFive = try date(2026, 11, 1, 1, 55, calendar: calendar)
        let secondOne = try XCTUnwrap(calendar.date(
            byAdding: .minute, value: 5, to: firstOneFiftyFive
        ))
        XCTAssertFalse(SleepAlarmEditorSupport.preservesTimeZoneOccurrence(
            endpoint: firstOneFiftyFive, proposed: secondOne, calendar: calendar
        ))
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}

private extension Int {
    var moduloDay: Int { ((self % 1_440) + 1_440) % 1_440 }
}
