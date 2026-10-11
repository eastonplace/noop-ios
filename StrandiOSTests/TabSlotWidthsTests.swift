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

    /// The shipped Spanish labels at AX on a 375pt phone: needs of about 395pt in a 375pt row. Scaling every slot by one
    /// fraction took the short "Hoy" slot to about 42pt although six touch targets (264pt) fit.
    func testAnOverfullRowKeepsTheShortSlotsAtATouchTarget() {
        let widths = TabSlotWidths.widths(ideals: [36, 76, 44, 74, 64, 58], total: 375)
        XCTAssertEqual(widths.reduce(0, +), 375, accuracy: 0.001)
        XCTAssertTrue(widths.allSatisfy { $0 >= TabSlotWidths.minimumSlot - 0.001 },
                      "no slot under a touch target while six fit: \(widths)")
        XCTAssertEqual(widths[0], TabSlotWidths.minimumSlot, accuracy: 0.001)
        // The long labels are the ones that gave way.
        XCTAssertLessThan(widths[1], 76 + TabSlotWidths.gutter)
    }

    func testLockingShortSlotsCanPutAnotherUnderTheTargetAndItIsLockedToo() {
        // Needs 44, 44, 50, 200 in 300pt: the first scale (0.76) takes only the two floors under 44, but once they are
        // locked the 50 falls under it too, so it is locked in the next pass and the long label gets the rest.
        let widths = TabSlotWidths.widths(ideals: [10, 10, 42, 192], total: 300)
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.001)
        XCTAssertEqual(widths[0], 44, accuracy: 0.001)
        XCTAssertEqual(widths[1], 44, accuracy: 0.001)
        XCTAssertEqual(widths[2], 44, accuracy: 0.001)
        XCTAssertEqual(widths[3], 168, accuracy: 0.001)
    }

    func testARowTooNarrowForSixTouchTargetsSharesEqually() {
        let widths = TabSlotWidths.widths(ideals: [40, 80, 40, 80, 80, 80], total: 240)
        XCTAssertEqual(widths, Array(repeating: 40, count: 6))
    }

    func testDegenerateInputsDoNotCrashOrGoNegative() {
        XCTAssertEqual(TabSlotWidths.widths(ideals: [], total: 300), [])
        XCTAssertEqual(TabSlotWidths.widths(ideals: [10, 10], total: 0), [0, 0])
        XCTAssertEqual(TabSlotWidths.widths(ideals: [10, 10], total: -5), [0, 0])
    }
}
