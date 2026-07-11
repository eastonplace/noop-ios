import XCTest
@testable import StrandDesign

final class StressTimelineSlotsTests: XCTestCase {
    func testEmptyDayStaysNeutral() {
        let slots = StressTimelineSlots.map([])
        XCTAssertEqual(slots.count, 24)
        XCTAssertTrue(slots.allSatisfy { $0 == nil })
    }

    func testPartialDayMapsOnlyMeasuredHours() {
        let slots = StressTimelineSlots.map([(6, 0.4), (7, nil), (8, 1.2)])
        XCTAssertEqual(slots[6], 0.4)
        XCTAssertNil(slots[7])
        XCTAssertEqual(slots[8], 1.2)
        XCTAssertEqual(slots.compactMap { $0 }.count, 2)
    }

    func testMixedBandsKeepTheirExactValues() {
        let slots = StressTimelineSlots.map([(9, 0.5), (10, 1.6), (11, 2.7)])
        XCTAssertEqual(slots[9], 0.5)
        XCTAssertEqual(slots[10], 1.6)
        XCTAssertEqual(slots[11], 2.7)
    }

    func testFullDayMapsWithoutChangingValues() {
        let slots = StressTimelineSlots.map((0..<24).map { ($0, Double($0) / 10) })
        XCTAssertEqual(slots.compactMap { $0 }.count, 24)
        XCTAssertEqual(slots[23], 2.3)
    }
}
