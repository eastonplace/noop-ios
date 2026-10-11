import XCTest
@testable import NOOP

/// How the accessibility-size tab bar shares its width between the slots.
final class TabSlotWidthsTests: XCTestCase {
    func testTheSlotsAlwaysFillTheRow() {
        let widths = TabSlotWidths.widths(ideals: [36, 45, 44, 42, 95, 42], total: 402)
        XCTAssertEqual(widths.reduce(0, +), 402, accuracy: 0.001)
    }

    func testALongLabelGetsMoreRoomThanAShortOne() {
        let widths = TabSlotWidths.widths(ideals: [36, 45, 44, 42, 95, 42], total: 402)
        XCTAssertGreaterThan(widths[4], widths[0])
        // Its slot holds the whole word: the slot is at least as wide as the word plus the gutter.
        XCTAssertGreaterThanOrEqual(widths[4], 95 + TabSlotWidths.gutter)
    }

    func testNoSlotIsUnderATouchTargetWhileThereIsRoom() {
        let widths = TabSlotWidths.widths(ideals: [10, 12, 44, 14, 20, 11], total: 402)
        XCTAssertTrue(widths.allSatisfy { $0 >= TabSlotWidths.minimumSlot })
    }

    func testEqualLabelsGetEqualSlots() {
        let widths = TabSlotWidths.widths(ideals: [40, 40, 40, 40], total: 400)
        XCTAssertEqual(widths, [100, 100, 100, 100])
    }

    func testAnOverfullRowShrinksEverySlotByTheSameFraction() {
        let ideals: [CGFloat] = [100, 100, 200]
        let widths = TabSlotWidths.widths(ideals: ideals, total: 200)
        XCTAssertEqual(widths.reduce(0, +), 200, accuracy: 0.001)
        // Needs are 108, 108, 208: scaled by 200 / 424.
        XCTAssertEqual(widths[0], 108 * 200 / 424, accuracy: 0.001)
        XCTAssertEqual(widths[2], 208 * 200 / 424, accuracy: 0.001)
    }

    func testDegenerateInputsDoNotCrashOrGoNegative() {
        XCTAssertEqual(TabSlotWidths.widths(ideals: [], total: 300), [])
        XCTAssertEqual(TabSlotWidths.widths(ideals: [10, 10], total: 0), [0, 0])
        XCTAssertEqual(TabSlotWidths.widths(ideals: [10, 10], total: -5), [0, 0])
    }
}
