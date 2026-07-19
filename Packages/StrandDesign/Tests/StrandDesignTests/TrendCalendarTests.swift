import XCTest
@testable import StrandDesign

final class TrendCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        return calendar
    }

    func testFiveWeekWindowIsMondayFirstAndKeepsMissingTuesday() throws {
        let today = try date(2026, 7, 17)
        let monday = try date(2026, 7, 13)
        let tuesday = try date(2026, 7, 14)
        let wednesday = try date(2026, 7, 15)

        let days = TrendCalendar.buildFiveWeekWindow(
            observations: [
                TrendCalendarDay(date: monday, value: 72),
                TrendCalendarDay(date: wednesday, value: 84),
            ],
            through: today,
            calendar: calendar
        )

        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(days.first).date), 2)
        XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(days.last).date), 1)
        XCTAssertEqual(days.first(where: { calendar.isDate($0.date, inSameDayAs: tuesday) })?.value, nil)
        XCTAssertEqual(days.first(where: { calendar.isDate($0.date, inSameDayAs: wednesday) })?.value, 84)
    }

    func testFiveWeekWindowSpansMonthBoundaryAndPreservesMultipleGaps() throws {
        let today = try date(2026, 8, 2)
        let july1 = try date(2026, 7, 1)
        let july31 = try date(2026, 7, 31)
        let days = TrendCalendar.buildFiveWeekWindow(
            observations: [TrendCalendarDay(date: july1, value: 30), TrendCalendarDay(date: july31, value: 90)],
            through: today,
            calendar: calendar
        )

        XCTAssertEqual(try components(of: XCTUnwrap(days.first)), DateComponents(year: 2026, month: 6, day: 29))
        XCTAssertEqual(try components(of: XCTUnwrap(days.last)), DateComponents(year: 2026, month: 8, day: 2))
        XCTAssertEqual(days.filter { $0.value == nil }.count, 33)
    }

    func testFiveWeekWindowAdvancesByCalendarDayAcrossDST() throws {
        let today = try date(2026, 3, 15)
        let days = TrendCalendar.buildFiveWeekWindow(observations: [], through: today, calendar: calendar)

        XCTAssertEqual(days.count, 35)
        for pair in zip(days, days.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day, 1)
            XCTAssertEqual(calendar.component(.hour, from: pair.1.date), 0)
        }
    }

    func testFutureDatesAreClassifiedSeparatelyFromMissingPastDates() throws {
        let today = try date(2026, 7, 17)
        let friday = try date(2026, 7, 17)
        let saturday = try date(2026, 7, 18)

        XCTAssertEqual(TrendCalendar.cellState(for: TrendCalendarDay(date: friday, value: nil), today: today, calendar: calendar), .missing)
        XCTAssertEqual(TrendCalendar.cellState(for: TrendCalendarDay(date: saturday, value: nil), today: today, calendar: calendar), .future)
        XCTAssertEqual(TrendCalendar.cellState(for: TrendCalendarDay(date: friday, value: 70), today: today, calendar: calendar), .value(70))
    }

    func testBestDayAgeUsesCalendarDistanceRatherThanArrayIndex() throws {
        let today = try date(2026, 7, 17)
        let best = try date(2026, 7, 12)
        let days = TrendCalendar.buildFiveWeekWindow(
            observations: [TrendCalendarDay(date: best, value: 95)],
            through: today,
            calendar: calendar
        )

        let result = try XCTUnwrap(TrendCalendar.best(in: days, relativeTo: today, calendar: calendar))
        XCTAssertEqual(result.value, 95)
        XCTAssertEqual(result.daysAgo, 5)
    }

    func testWeekdayAveragesGroupActualDatesAndExcludeMissingValues() throws {
        let monday1 = try date(2026, 7, 6)
        let monday2 = try date(2026, 7, 13)
        let wednesday = try date(2026, 7, 15)
        let days = [
            TrendCalendarDay(date: monday1, value: 40),
            TrendCalendarDay(date: monday2, value: 80),
            TrendCalendarDay(date: try date(2026, 7, 14), value: nil),
            TrendCalendarDay(date: wednesday, value: 90),
        ]

        let averages = TrendCalendar.weekdayAverages(days, calendar: calendar)

        XCTAssertEqual(averages.count, 7)
        XCTAssertEqual(averages[0], 60)
        XCTAssertNil(averages[1])
        XCTAssertEqual(averages[2], 90)
    }

    func testCalendarWeekPlacesSundayInSeventhSlotAndKeepsTuesdayGap() throws {
        let sunday = try date(2026, 7, 19)
        let monday = try date(2026, 7, 13)
        let wednesday = try date(2026, 7, 15)
        let days = TrendCalendar.buildWeekWindow(
            observations: [
                TrendCalendarDay(date: monday, value: 4),
                TrendCalendarDay(date: wednesday, value: 8),
                TrendCalendarDay(date: sunday, value: 12),
            ],
            containing: sunday,
            calendar: calendar
        )

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].value, 4)
        XCTAssertNil(days[1].value)
        XCTAssertEqual(days[2].value, 8)
        XCTAssertEqual(days[6].value, 12)
    }

    func testRollingWindowKeepsMissingTodayAndExactYesterday() throws {
        let today = try date(2026, 7, 19)
        let yesterday = try date(2026, 7, 18)
        let older = try date(2026, 7, 15)
        let days = TrendCalendar.buildRollingWindow(
            observations: [
                TrendCalendarDay(date: older, value: 50),
                TrendCalendarDay(date: yesterday, value: 70),
            ],
            through: today,
            count: 7,
            calendar: calendar
        )

        XCTAssertEqual(days.count, 7)
        XCTAssertNil(days.last?.value)
        XCTAssertEqual(TrendCalendar.value(on: yesterday, in: days, calendar: calendar), 70)
        XCTAssertNil(TrendCalendar.value(on: today, in: days, calendar: calendar))
        XCTAssertEqual(TrendCalendar.mean(of: days), 60)
    }

    func testRollingWindowAdvancesAcrossDSTAndMonthBoundary() throws {
        let today = try date(2026, 3, 10)
        let days = TrendCalendar.buildRollingWindow(
            observations: [], through: today, count: 14, calendar: calendar)

        XCTAssertEqual(days.count, 14)
        for pair in zip(days, days.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day, 1)
        }
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(days.first).date), 2)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(days.first).date), 25)
    }

    func testRangeDomainAndRelativeLabelsUseCalendarDates() throws {
        let today = try date(2026, 7, 19)
        let domain = try XCTUnwrap(TrendCalendar.dateDomain(through: today, count: 30, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day, 29)
        XCTAssertEqual(TrendCalendar.relativeLabel(for: today, relativeTo: today, calendar: calendar), "Today")
        XCTAssertEqual(TrendCalendar.relativeLabel(for: try date(2026, 7, 18), relativeTo: today, calendar: calendar), "Yesterday")
        XCTAssertEqual(TrendCalendar.relativeLabel(for: try date(2026, 7, 15), relativeTo: today, calendar: calendar), "Wed, Jul 15")
    }

    func testDatePositionPreservesCalendarGap() throws {
        let start = try date(2026, 7, 13)
        let end = try date(2026, 7, 19)
        let wednesday = try date(2026, 7, 15)
        let sunday = try date(2026, 7, 19)
        let domain = start...end

        XCTAssertEqual(TrendCalendar.unitPosition(of: wednesday, in: domain), 2.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(TrendCalendar.unitPosition(of: sunday, in: domain), 1, accuracy: 0.0001)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private func components(of day: TrendCalendarDay) throws -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: day.date)
    }
}
