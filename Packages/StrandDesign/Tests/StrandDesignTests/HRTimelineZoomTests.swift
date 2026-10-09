import XCTest
@testable import StrandDesign

/// The Deep Timeline's pinch and pan maths: zooming out stops at the day, zooming in stops at the floor, and a
/// window that is the whole day is recognised as such.
final class HRTimelineZoomTests: XCTestCase {
    private let day: ClosedRange<TimeInterval> = 0...86_400
    private let threeDays: ClosedRange<TimeInterval> = -172_800...86_400

    func testPinchOutStopsAtTheDayEvenWhenThePanRangeIsThreeDays() {
        let zoomed = HRTimelineChart.zoomed(
            21_600...43_200, scale: 0.01, anchorFraction: 0.5, bounds: day, maxSpan: 86_400)
        XCTAssertEqual(zoomed, day)
    }

    func testPinchOutCapHoldsInsideTheWiderPanRange() {
        // A window already dragged back past midnight may roam the three-day range, but never grows past a day.
        let zoomed = HRTimelineChart.zoomed(
            -50_000...(-20_000), scale: 0.001, anchorFraction: 0.5, bounds: threeDays, maxSpan: 86_400)
        XCTAssertEqual(zoomed.upperBound - zoomed.lowerBound, 86_400, accuracy: 1)
        XCTAssertGreaterThanOrEqual(zoomed.lowerBound, threeDays.lowerBound)
        XCTAssertLessThanOrEqual(zoomed.upperBound, threeDays.upperBound)
    }

    func testWithoutACapThePinchStillFillsTheBounds() {
        let zoomed = HRTimelineChart.zoomed(
            21_600...43_200, scale: 0.001, anchorFraction: 0.5, bounds: threeDays)
        XCTAssertEqual(zoomed, threeDays)
    }

    func testPinchInStopsAtTheFloor() {
        let zoomed = HRTimelineChart.zoomed(
            0...86_400, scale: 10_000, anchorFraction: 0.5, bounds: day, maxSpan: 86_400)
        XCTAssertEqual(zoomed.upperBound - zoomed.lowerBound, HRTimelineChart.minZoomSpan, accuracy: 1)
    }

    func testPinchKeepsTheWindowInsideTheDay() {
        let zoomed = HRTimelineChart.zoomed(
            0...7_200, scale: 0.5, anchorFraction: 0, bounds: day, maxSpan: 86_400)
        XCTAssertGreaterThanOrEqual(zoomed.lowerBound, day.lowerBound)
        XCTAssertLessThanOrEqual(zoomed.upperBound, day.upperBound)
    }

    func testContainsToleratesASecondOfRounding() {
        XCTAssertTrue(HRTimelineChart.contains(day, 0...86_400))
        XCTAssertTrue(HRTimelineChart.contains(day, 0.5...86_400.5))
        XCTAssertFalse(HRTimelineChart.contains(day, -60...86_400))
        XCTAssertFalse(HRTimelineChart.contains(0...43_200, day))
    }

    func testPanClampsToTheRange() {
        let panned = HRTimelineChart.panned(0...21_600, delta: -1_000_000, bounds: threeDays)
        XCTAssertEqual(panned.lowerBound, threeDays.lowerBound)
        XCTAssertEqual(panned.upperBound - panned.lowerBound, 21_600, accuracy: 1e-9)
    }
}
