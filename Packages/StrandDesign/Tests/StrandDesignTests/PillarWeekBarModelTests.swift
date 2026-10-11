import XCTest
@testable import StrandDesign

final class PillarWeekBarModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Monday 5 Oct to Sunday 11 Oct 2026.
    private func week(_ values: [Double?]) -> [CalendarMetricDay] {
        values.enumerated().map { index, value in
            CalendarMetricDay(date: calendar.date(from: DateComponents(year: 2026, month: 10, day: 5 + index))!, value: value)
        }
    }

    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day))! }

    private func slots(_ values: [Double?], anchor: Int = 10, today: Int = 10) -> [PillarWeekBarSlot] {
        PillarWeekBarModel.slots(days: week(values), maximum: 21, anchorDate: date(anchor),
                                 referenceDate: date(today), calendar: calendar)
    }

    func testADayWithAScoreIsABarOnTheFixedScale() {
        let result = slots([10.5, nil, nil, nil, nil, nil, nil])
        XCTAssertEqual(result[0].kind, .value(10.5))
        XCTAssertEqual(try XCTUnwrap(result[0].fraction), 0.5, accuracy: 0.0001)
    }

    func testAPastDayWithoutAScoreIsAMissingDotNotAZeroBar() {
        let result = slots([5, nil, 7, 8, 9, 12, nil])
        XCTAssertEqual(result[1].kind, .missing)
        XCTAssertNil(result[1].fraction)
    }

    func testDaysAfterTodayAreFutureEvenWhenTheyHoldAValue() {
        let result = slots([5, 6, 7, 8, 9, 12, 14], today: 10)
        XCTAssertEqual(result[5].kind, .value(12))
        XCTAssertEqual(result[6].kind, .future)
        XCTAssertNil(result[6].fraction)
    }

    func testTheViewedDayIsTheAnchorAndOnlyThatOne() {
        let result = slots([5, 6, 7, 8, 9, 12, nil], anchor: 8)
        XCTAssertEqual(result.map(\.isAnchor), [false, false, false, true, false, false, false])
    }

    func testAValueBeyondTheScaleIsClampedAndANonFiniteOneIsMissing() {
        let result = slots([25, .nan, -3, nil, nil, nil, nil])
        XCTAssertEqual(try XCTUnwrap(result[0].fraction), 1, accuracy: 0.0001)
        XCTAssertEqual(result[1].kind, .missing)
        XCTAssertEqual(try XCTUnwrap(result[2].fraction), 0, accuracy: 0.0001)
    }

    func testVoiceOverNamesTheMissingAndTheUpcomingDaysAndNeverCallsAFutureDayMissing() {
        let result = slots([5, nil, 7, 8, 9, 12, nil], today: 10)
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let spoken = PillarWeekBarModel.spokenSummary(
            result, dayNames: names, value: { "\($0) of 21" }, noData: "no data", upcoming: "Upcoming")
        XCTAssertEqual(spoken, "Monday 5.0 of 21, Tuesday no data, Wednesday 7.0 of 21, Thursday 8.0 of 21, "
            + "Friday 9.0 of 21, Saturday 12.0 of 21, Sunday Upcoming")
    }

    func testVoiceOverMarksTheViewedDayAndJoinsNameAndReadingThroughTheGivenFormats() {
        let result = slots([5, nil, 7, 8, 9, 12, nil], anchor: 8, today: 10)
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let spoken = PillarWeekBarModel.spokenSummary(
            result, dayNames: names, value: { "\($0)" }, noData: "none", upcoming: "later",
            reading: { "\($0): \($1)" }, viewed: { "\($0) (viewed)" })
        XCTAssertEqual(spoken, "Mon: 5.0, Tue: none, Wed: 7.0, Thu: 8.0 (viewed), Fri: 9.0, Sat: 12.0, Sun: later")
    }


    func testOnlySevenSlotsComeBack() {
        XCTAssertEqual(slots([1, 2, 3, 4, 5, 6, 7, 8, 9]).count, 7)
        XCTAssertEqual(slots([]).count, 0)
    }
}
