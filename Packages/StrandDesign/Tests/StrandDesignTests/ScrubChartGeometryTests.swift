import XCTest
@testable import StrandDesign

/// The geometry behind `ScrubChart`: where a date lands, which point a finger is nearest, and how many labels fit.
final class ScrubChartGeometryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var domain: ClosedRange<Date> { start...start.addingTimeInterval(86_400 * 10) }

    func testUnitPositionSpansTheDomainAndClampsOutsideIt() {
        XCTAssertEqual(ScrubChartGeometry.unitPosition(of: start, in: domain), 0, accuracy: 1e-9)
        XCTAssertEqual(ScrubChartGeometry.unitPosition(of: start.addingTimeInterval(86_400 * 5), in: domain), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ScrubChartGeometry.unitPosition(of: domain.upperBound, in: domain), 1, accuracy: 1e-9)
        XCTAssertEqual(ScrubChartGeometry.unitPosition(of: start.addingTimeInterval(-1), in: domain), 0, accuracy: 1e-9)
        XCTAssertEqual(ScrubChartGeometry.unitPosition(of: domain.upperBound.addingTimeInterval(1), in: domain), 1, accuracy: 1e-9)
    }

    func testAZeroLengthDomainCentresEverything() {
        XCTAssertEqual(ScrubChartGeometry.unitPosition(of: start, in: start...start), 0.5, accuracy: 1e-9)
    }

    func testNearestIndexPicksTheClosestPointAndHandlesNone() {
        XCTAssertNil(ScrubChartGeometry.nearestIndex(toX: 10, in: []))
        let xs: [CGFloat] = [0, 40, 100, 160]
        XCTAssertEqual(ScrubChartGeometry.nearestIndex(toX: -50, in: xs), 0)
        XCTAssertEqual(ScrubChartGeometry.nearestIndex(toX: 61, in: xs), 1)
        XCTAssertEqual(ScrubChartGeometry.nearestIndex(toX: 71, in: xs), 2)
        XCTAssertEqual(ScrubChartGeometry.nearestIndex(toX: 900, in: xs), 3)
    }

    func testAtMostFourLabelsAndTwoAtAccessibilitySizes() {
        XCTAssertEqual(ScrubChartGeometry.labelCount(isAccessibilitySize: false), 4)
        XCTAssertEqual(ScrubChartGeometry.labelCount(isAccessibilitySize: true), 2)
    }

    func testLabelDatesRunFirstToLastEvenly() {
        let four = ScrubChartGeometry.labelDates(in: domain, count: 4)
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(four.first, domain.lowerBound)
        XCTAssertEqual(four.last, domain.upperBound)
        let steps = zip(four.dropFirst(), four).map { $0.timeIntervalSince($1) }
        XCTAssertTrue(steps.allSatisfy { abs($0 - steps[0]) < 1e-6 })
        XCTAssertEqual(ScrubChartGeometry.labelDates(in: domain, count: 1), [domain.lowerBound])
    }

    func testBarWidthStaysBetweenThreeAndTwentyTwoPoints() {
        XCTAssertEqual(ScrubChartGeometry.barWidth(minimumGapFraction: 0.001, plotWidth: 300), 3)
        XCTAssertEqual(ScrubChartGeometry.barWidth(minimumGapFraction: 1, plotWidth: 300), 22)
        let middle = ScrubChartGeometry.barWidth(minimumGapFraction: 0.08, plotWidth: 300)
        XCTAssertEqual(middle, 0.08 * 300 * 0.62, accuracy: 1e-6)
    }
}
