import XCTest
@testable import StrandDesign

final class LeadingEdgeStripTests: XCTestCase {
    func testTheLeadingEdgeStripIsAThumbWideOnTheLeadingSideOnly() {
        XCTAssertTrue(LeadingEdgeStrip.contains(x: 0, in: 390, leftToRight: true))
        XCTAssertTrue(LeadingEdgeStrip.contains(x: 23.9, in: 390, leftToRight: true))
        XCTAssertFalse(LeadingEdgeStrip.contains(x: 24, in: 390, leftToRight: true))
        XCTAssertFalse(LeadingEdgeStrip.contains(x: 370, in: 390, leftToRight: true))
        // Right to left, the leading edge is the right one.
        XCTAssertTrue(LeadingEdgeStrip.contains(x: 390, in: 390, leftToRight: false))
        XCTAssertTrue(LeadingEdgeStrip.contains(x: 366.1, in: 390, leftToRight: false))
        XCTAssertFalse(LeadingEdgeStrip.contains(x: 366, in: 390, leftToRight: false))
        XCTAssertFalse(LeadingEdgeStrip.contains(x: 10, in: 390, leftToRight: false))
    }
}
