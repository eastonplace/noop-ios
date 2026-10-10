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

    private func slots(_ values: [Double?], anchor: Int = 10, today: Int = 10, target: ClosedRange<Double>? = 14...18) -> [PillarWeekBarSlot] {
        PillarWeekBarModel.slots(days: week(values), maximum: 21, target: target, anchorDate: date(anchor),
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
        XCTAssertNil(result[1].reachesTarget)
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

    func testAValueReachesTheTargetAtItsFloor() {
        let result = slots([13.9, 14, 17, 18, 21, nil, nil])
        XCTAssertEqual(result.prefix(5).map(\.reachesTarget), [false, true, true, true, true])
        XCTAssertEqual(slots([14, nil, nil, nil, nil, nil, nil], target: nil)[0].reachesTarget, nil)
    }

    func testAValueBeyondTheScaleIsClampedAndANonFiniteOneIsMissing() {
        let result = slots([25, .nan, -3, nil, nil, nil, nil])
        XCTAssertEqual(try XCTUnwrap(result[0].fraction), 1, accuracy: 0.0001)
        XCTAssertEqual(result[1].kind, .missing)
        XCTAssertEqual(try XCTUnwrap(result[2].fraction), 0, accuracy: 0.0001)
    }

    func testOnlySevenSlotsComeBack() {
        XCTAssertEqual(slots([1, 2, 3, 4, 5, 6, 7, 8, 9]).count, 7)
        XCTAssertEqual(slots([]).count, 0)
    }
}
