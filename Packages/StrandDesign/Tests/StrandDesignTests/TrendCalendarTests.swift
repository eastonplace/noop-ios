import XCTest
@testable import StrandDesign

final class TrendCalendarTests: XCTestCase {

    func testFiniteChartScaleNormalizesOpposingFiniteExtremes() throws {
        let maximum = Double.greatestFiniteMagnitude
        let scale = try XCTUnwrap(FiniteChartScale(values: [-maximum, maximum]))
        for value in [-maximum, 0, maximum] {
            let normalized = try XCTUnwrap(scale.normalized(value))
            XCTAssertTrue(normalized.isFinite)
            XCTAssertTrue((0...1).contains(normalized))
        }
    }
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

    func testEqualLengthPeriodsAreAdjacentAndDoNotOverlap() throws {
        let today = try date(2026, 7, 19)
        let current = try XCTUnwrap(TrendCalendar.equalLengthPeriod(
            through: today, count: 30, periodOffset: 0, calendar: calendar
        ))
        let previous = try XCTUnwrap(TrendCalendar.equalLengthPeriod(
            through: today, count: 30, periodOffset: -1, calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.day], from: current.lowerBound, to: current.upperBound).day, 29)
        XCTAssertEqual(calendar.dateComponents([.day], from: previous.lowerBound, to: previous.upperBound).day, 29)
        XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: previous.upperBound), current.lowerBound)
        XCTAssertLessThan(previous.upperBound, current.lowerBound)
    }

    func testEqualLengthPeriodUsesCalendarDaysAcrossDST() throws {
        let today = try date(2026, 3, 15)
        let period = try XCTUnwrap(TrendCalendar.equalLengthPeriod(
            through: today, count: 14, periodOffset: 0, calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.day], from: period.lowerBound, to: period.upperBound).day, 13)
        XCTAssertEqual(calendar.component(.hour, from: period.lowerBound), 0)
        XCTAssertEqual(calendar.component(.hour, from: period.upperBound), 0)
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

    func testScrubSelectsExactCalendarSlotWithoutSnappingAcrossGap() throws {
        let days = TrendCalendar.buildRollingWindow(
            observations: [
                TrendCalendarDay(date: try date(2026, 7, 13), value: 40),
                TrendCalendarDay(date: try date(2026, 7, 15), value: 80),
            ],
            through: try date(2026, 7, 19),
            count: 7,
            calendar: calendar
        )

        let tuesday = try XCTUnwrap(TrendCalendar.day(atUnitPosition: 1.0 / 6.0, in: days))
        XCTAssertEqual(try components(of: tuesday), DateComponents(year: 2026, month: 7, day: 14))
        XCTAssertNil(tuesday.value)

        let sunday = try XCTUnwrap(TrendCalendar.day(atUnitPosition: 1, in: days))
        XCTAssertEqual(try components(of: sunday), DateComponents(year: 2026, month: 7, day: 19))
    }

    func testHeatmapScrubMapsTouchToExactMondayFirstCell() {
        XCTAssertEqual(TrendCalendar.gridIndex(xFraction: 0, yFraction: 0, columns: 7, count: 35), 0)
        XCTAssertEqual(TrendCalendar.gridIndex(xFraction: 0.99, yFraction: 0, columns: 7, count: 35), 6)
        XCTAssertEqual(TrendCalendar.gridIndex(xFraction: 0.5, yFraction: 0.5, columns: 7, count: 35), 17)
        XCTAssertEqual(TrendCalendar.gridIndex(xFraction: 1, yFraction: 1, columns: 7, count: 35), 34)
    }

    func testCurrentWeekdayIndexIsMondayFirstAndPlacesSundayLast() throws {
        XCTAssertEqual(
            TrendCalendar.mondayFirstWeekdayIndex(for: try date(2026, 7, 13), calendar: calendar),
            0
        )
        XCTAssertEqual(
            TrendCalendar.mondayFirstWeekdayIndex(for: try date(2026, 7, 19), calendar: calendar),
            6
        )
    }

    func testRangeAverageHeadingsAreExactAndRangeAware() {
        XCTAssertEqual(TrendRange.week.averageHeading, "AVERAGE · LAST 7 DAYS")
        XCTAssertEqual(TrendRange.month.averageHeading, "AVERAGE · LAST 30 DAYS")
        XCTAssertEqual(TrendRange.quarter.averageHeading, "AVERAGE · LAST 90 DAYS")
        XCTAssertEqual(TrendRange.half.averageHeading, "AVERAGE · LAST 180 DAYS")
        XCTAssertEqual(TrendRange.week.summarySubtitle, "Last 7 days · vs prior 7")
        XCTAssertEqual(TrendRange.month.summarySubtitle, "Last 30 days · vs prior 30")
    }

    func testWeekdayScrubIndexUsesSevenEqualHitRegions() {
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: -1), 0)
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: 0), 0)
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: 0.10), 0)
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: 0.90), 6)
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: 0.5), 3)
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: 1), 6)
        XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: 2), 6)
        for boundary in 1...6 {
            let value = Double(boundary) / 7
            XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: value.nextDown), boundary - 1)
            XCTAssertEqual(TrendCalendar.weekdayIndex(atUnitPosition: value), boundary)
        }
    }

    // MARK: A day with no midnight

    /// Egypt's clocks went from 00:00 to 01:00 on 24 April 2026, so that day starts at 01:00 and a date built by adding days to
    /// an earlier midnight lands on 01:00 and stays there.
    private func cairo() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Africa/Cairo"))
        calendar.firstWeekday = 2
        let skipped = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24)))
        try XCTSkipUnless(calendar.component(.hour, from: skipped) == 1, "no midnight clock change for Cairo in this system's time zone data")
        return calendar
    }

    /// One reading a day from `first` to `last`, each stamped at the start of its day as the Explorer stamps them.
    private func dailyReadings(from first: Date, to last: Date, in calendar: Calendar) -> [CalendarMetricDay] {
        var readings: [CalendarMetricDay] = []
        var day = first
        var value = 1.0
        while day <= last {
            readings.append(CalendarMetricDay(date: day, value: value))
            value += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return readings
    }

    /// The whole history from the day with no midnight: every day is a slot with its own reading, and the first slot is the
    /// domain's first instant.
    func testAnAllTimeWindowStartingOnTheSkippedMidnightKeepsEveryDay() throws {
        let calendar = try cairo()
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24)))
        let last = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30)))
        let readings = dailyReadings(from: first, to: last, in: calendar)
        XCTAssertEqual(readings.count, 68)

        let days = TrendCalendar.buildRollingWindow(observations: readings, through: last, count: 68, calendar: calendar)
        XCTAssertEqual(days.count, 68)
        XCTAssertEqual(days.compactMap(\.value), readings.compactMap(\.value), "Every day keeps its own reading")
        XCTAssertEqual(days.map(\.date), readings.map(\.date), "Every slot sits at the start of its day")
        let domain = try XCTUnwrap(TrendCalendar.dateDomain(through: last, count: 68, calendar: calendar))
        XCTAssertEqual(domain.lowerBound, first)
        XCTAssertEqual(domain.lowerBound, days.first?.date)
        XCTAssertEqual(domain.upperBound, days.last?.date)
    }

    /// A week that ends on the day with no midnight, and one that starts on it.
    func testAWeekThatEndsOrStartsOnTheSkippedMidnightKeepsEveryDay() throws {
        let calendar = try cairo()
        let skipped = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24)))
        let thirtieth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 30)))
        let eighteenth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 18)))

        let ending = TrendCalendar.buildRollingWindow(
            observations: dailyReadings(from: eighteenth, to: skipped, in: calendar), through: skipped, count: 7, calendar: calendar)
        XCTAssertEqual(ending.compactMap(\.value), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ending.first?.date, eighteenth)
        XCTAssertEqual(ending.last?.date, skipped)

        let starting = TrendCalendar.buildRollingWindow(
            observations: dailyReadings(from: skipped, to: thirtieth, in: calendar), through: thirtieth, count: 7, calendar: calendar)
        XCTAssertEqual(starting.compactMap(\.value), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(starting.first?.date, skipped)
        XCTAssertEqual(try XCTUnwrap(TrendCalendar.dateDomain(through: thirtieth, count: 7, calendar: calendar)).lowerBound, skipped)
    }

    /// The month grid and the equal-length periods count on from the same instants.
    func testTheMonthGridAndTheEqualLengthPeriodsSurviveTheSkippedMidnight() throws {
        let calendar = try cairo()
        let skipped = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 8)))
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 6)))
        let readings = dailyReadings(from: first, to: today, in: calendar)
            .map { TrendCalendarDay(date: $0.date, value: $0.value) }

        let grid = TrendCalendar.buildFiveWeekWindow(observations: readings, through: today, calendar: calendar)
        XCTAssertEqual(grid.count, 35)
        XCTAssertTrue(grid.map(\.date).allSatisfy { calendar.startOfDay(for: $0) == $0 }, "Every cell starts its day")
        XCTAssertEqual(try XCTUnwrap(grid.first { $0.date == skipped }).value, 19)
        XCTAssertEqual(grid.compactMap(\.value).count, 33, "6 April to 8 May, all present")

        let week = try XCTUnwrap(TrendCalendar.equalLengthPeriod(through: skipped, count: 7, periodOffset: 1, calendar: calendar))
        XCTAssertEqual(week.lowerBound, calendar.startOfDay(for: week.lowerBound))
        XCTAssertEqual(calendar.component(.day, from: week.lowerBound), 25)
    }

    /// Days are counted as days, not as elapsed clock time: a day that starts at 01:00 is a whole day.
    func testWholeDaysAreCountedAcrossTheSkippedMidnight() throws {
        let calendar = try cairo()
        let skipped = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24)))
        let sixth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30)))
        XCTAssertEqual(TrendCalendar.dayCount(from: skipped, to: sixth, calendar: calendar), 6)
        XCTAssertEqual(TrendCalendar.dayCount(from: skipped, to: end, calendar: calendar), 67)
        XCTAssertEqual(TrendCalendar.dayCount(from: sixth, to: skipped, calendar: calendar), -6)
        XCTAssertEqual(TrendCalendar.dayCount(from: skipped, to: skipped, calendar: calendar), 0)
        // Clock times inside a day do not matter.
        let evening = try XCTUnwrap(calendar.date(byAdding: .hour, value: 20, to: skipped))
        XCTAssertEqual(TrendCalendar.dayCount(from: evening, to: sixth, calendar: calendar), 6)
        // The same on an ordinary day.
        XCTAssertEqual(TrendCalendar.dayCount(from: try date(2026, 3, 1), to: try date(2026, 3, 8), calendar: self.calendar), 7)
    }

    /// Two adjacent days never read the same, and the skipped day counts from its own day: with 25 April as the reference, 24 April
    /// is Yesterday (not Today), and from 26 April it is two days back (not Yesterday).
    func testRelativeLabelsAreRightForTheSkippedMidnightDay() throws {
        let calendar = try cairo()
        let skipped = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24)))
        let twentyFifth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 25)))
        let twentySixth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 26)))
        let today = TrendCalendar.relativeLabel(for: twentyFifth, relativeTo: twentyFifth, calendar: calendar)
        let yesterday = TrendCalendar.relativeLabel(for: skipped, relativeTo: twentyFifth, calendar: calendar)
        XCTAssertNotEqual(today, yesterday)
        XCTAssertEqual(yesterday, TrendCalendar.relativeLabel(for: twentyFifth, relativeTo: twentySixth, calendar: calendar))
        let twoBack = TrendCalendar.relativeLabel(for: skipped, relativeTo: twentySixth, calendar: calendar)
        XCTAssertNotEqual(twoBack, yesterday)
        XCTAssertNotEqual(twoBack, today)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private func components(of day: TrendCalendarDay) throws -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: day.date)
    }
}
