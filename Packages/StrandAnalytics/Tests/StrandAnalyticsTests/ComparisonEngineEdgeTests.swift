import XCTest
@testable import StrandAnalytics

final class ComparisonEngineEdgeTests: XCTestCase {
    func testMedianReturnsZeroWhenAllInputsAreNonFinite() {
        XCTAssertEqual(ComparisonEngine.median([.nan, .infinity, -.infinity]), 0)
    }

    func testStatDropsAllNonFiniteInputsWithoutIndexingAnEmptyMedian() {
        XCTAssertEqual(ComparisonEngine.stat([.nan, .infinity, -.infinity]), .empty)
    }
}
