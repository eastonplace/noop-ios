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
}
