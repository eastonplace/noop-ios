import XCTest
@testable import StrandAnalytics

final class StableStatisticsTests: XCTestCase {
    func testRoundedIntRejectsFloatingPointBoundaryAboveIntMax() {
        // On 64-bit Swift, Double(Int.max) rounds to 2^63 and is not representable as Int.
        XCTAssertNil(StableStatistics.roundedInt(Double(Int.max)))
        XCTAssertEqual(StableStatistics.roundedInt(Double(Int.min)), Int.min)
    }

    func testRoundedIntRoundsOnlyRepresentableFiniteValues() {
        XCTAssertEqual(StableStatistics.roundedInt(42.6), 43)
        XCTAssertEqual(StableStatistics.roundedInt(-42.6), -43)
        XCTAssertNil(StableStatistics.roundedInt(.infinity))
        XCTAssertNil(StableStatistics.roundedInt(.nan))
    }

    func testFiniteExtremeStatisticsSaturateInsteadOfBecomingNilOrZero() throws {
        let maximum = Double.greatestFiniteMagnitude
        XCTAssertEqual(StableStatistics.mean([maximum, -maximum]), 0)
        XCTAssertEqual(
            try XCTUnwrap(StableStatistics.sampleStandardDeviation([maximum, -maximum], mean: 0)),
            maximum
        )
        XCTAssertEqual(
            try XCTUnwrap(StableStatistics.difference(maximum, -maximum)),
            maximum
        )
        XCTAssertEqual(
            try XCTUnwrap(StableStatistics.difference(-maximum, maximum)),
            -maximum
        )
        XCTAssertEqual(
            try XCTUnwrap(StableStatistics.leastSquaresSlope([-maximum, maximum])),
            maximum
        )
    }

    func testPercentChangeUsesNormalizedRatioBeforeAbsoluteDeltaSaturates() throws {
        let maximum = Double.greatestFiniteMagnitude
        XCTAssertEqual(
            try XCTUnwrap(StableStatistics.percentChange(current: maximum, previous: -maximum)),
            200
        )
        XCTAssertEqual(
            try XCTUnwrap(StableStatistics.percentChange(current: -maximum, previous: maximum)),
            -200
        )
    }
}
