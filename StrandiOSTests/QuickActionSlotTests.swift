import XCTest
import StrandDesign
@testable import NOOP

/// Pins where the Quick Actions fan puts each action: Start workout and Strength side by side on top, the other four
/// arcing down to the +, every circle and label clear of the screen's edge on the narrowest supported phone.
/// Pure geometry, no UI host needed.
final class QuickActionSlotTests: XCTestCase {
    private typealias Slot = QuickActionSlot

    /// iPhone SE / mini (the narrowest the iOS 17 floor supports) up to the largest Pro Max.
    private let widths: [CGFloat] = [375, 390, 393, 402, 430, 440]

    private func centre(_ slot: Slot, width: CGFloat) -> CGPoint {
        slot.centre(plus: CGPoint(x: width / 2, y: 0), width: width)
    }

    func testReferenceScreenUsesTheDesignedOffsets() {
        let expected: [(Slot, CGFloat, CGFloat)] = [
            (.journal, -152.5, -118), (.live, -126.5, -215), (.workout, -48.5, -262),
            (.strength, 48.5, -262), (.intervals, 126.5, -215), (.breathe, 152.5, -118),
        ]
        for (slot, dx, dy) in expected {
            let point = centre(slot, width: Slot.referenceWidth)
            XCTAssertEqual(point.x - Slot.referenceWidth / 2, dx, accuracy: 0.001, "\(slot)")
            XCTAssertEqual(point.y, dy, accuracy: 0.001, "\(slot)")
        }
    }

    func testStrengthIsAPrimaryBesideStartWorkout() {
        XCTAssertEqual(Slot.allCases.filter(\.isPrimary), [.workout, .strength])
        XCTAssertEqual(Slot.workout.diameter, Slot.strength.diameter)
        XCTAssertGreaterThan(Slot.workout.diameter, Slot.journal.diameter)
        XCTAssertEqual(Slot.workout.offset.y, Slot.strength.offset.y)
        XCTAssertEqual(Slot.workout.offset.x, -Slot.strength.offset.x)
        // Workout is the left one, Strength the right one, the secondaries below them.
        XCTAssertLessThan(Slot.workout.offset.x, 0)
        for slot in Slot.allCases where !slot.isPrimary {
            XCTAssertGreaterThan(slot.offset.y, Slot.workout.offset.y, "\(slot)")
        }
    }

    func testEveryCircleAndLabelStaysClearOfTheScreenEdge() {
        for width in widths {
            for slot in Slot.allCases {
                let x = centre(slot, width: width).x
                let circleEdge = min(x - slot.diameter / 2, width - (x + slot.diameter / 2))
                XCTAssertGreaterThanOrEqual(circleEdge, Slot.edgeMargin - 0.001, "\(slot) circle at \(width)")
                let label = slot.labelWidth(width: width, maximum: 92)
                let labelEdge = min(x - label / 2, width - (x + label / 2))
                XCTAssertGreaterThanOrEqual(labelEdge, Slot.edgeMargin - 0.001, "\(slot) label at \(width)")
                // Wide enough to tap, and to hold a one-word label.
                XCTAssertGreaterThanOrEqual(label, 56, "\(slot) label at \(width)")
            }
        }
    }

    func testNothingOverlaps() {
        for width in widths {
            let slots = Slot.allCases
            for (index, a) in slots.enumerated() {
                for b in slots[(index + 1)...] {
                    let pa = centre(a, width: width), pb = centre(b, width: width)
                    let gap = hypot(pa.x - pb.x, pa.y - pb.y) - (a.diameter + b.diameter) / 2
                    XCTAssertGreaterThan(gap, 8, "\(a) and \(b) circles at \(width)")
                }
            }
            // The two top labels sit side by side without touching.
            let left = centre(.workout, width: width).x + Slot.workout.labelWidth(width: width, maximum: 92) / 2
            let right = centre(.strength, width: width).x - Slot.strength.labelWidth(width: width, maximum: 92) / 2
            XCTAssertLessThanOrEqual(left, right, "top labels at \(width)")
        }
    }

    /// One line of the 13pt label at the largest size the arc allows (xxxLarge), the tallest a secondary label gets.
    private let labelLine: CGFloat = 20

    func testTheLowestLabelsClearTheTabBar() throws {
        // The + sits on the middle of the bar's row, so its centre is half a row above the bottom; the bar's top edge is its
        // hairline, one point over the row.
        let tabBarTop = -(NoopMetrics.navBarHeight / 2 + 1)
        let secondaries = Slot.allCases.filter { !$0.isPrimary }
        let lowest = try XCTUnwrap(secondaries.map { $0.offset.y + $0.diameter / 2 + Slot.labelGap + labelLine }.max())
        XCTAssertGreaterThanOrEqual(tabBarTop - lowest, 16)
    }

    func testALabelClearsTheCircleBelowIt() {
        // Live HR's label hangs over Journal's circle, and Intervals' over Breathe's.
        for (upper, lower) in [(Slot.live, Slot.journal), (.intervals, .breathe)] {
            let labelBottom = upper.offset.y + upper.diameter / 2 + Slot.labelGap + labelLine
            XCTAssertGreaterThanOrEqual(lower.offset.y - lower.diameter / 2 - labelBottom, 8, "\(upper) over \(lower)")
        }
    }

    func testTheRecentSportChipSitsClearAboveTheTopCircles() {
        let capsuleBottom = Slot.chipOffsetY + 18
        let circleTop = Slot.workout.offset.y - Slot.workout.diameter / 2
        XCTAssertGreaterThanOrEqual(circleTop - capsuleBottom, 12)
        // Its 44pt tap frame does not reach the circles either.
        XCTAssertLessThan(Slot.chipOffsetY + 22, circleTop)
    }

    func testHorizontalOffsetsScaleWithTheScreenWidth() {
        let wide = centre(.live, width: 440).x - 220
        let narrow = centre(.live, width: 375).x - 187.5
        XCTAssertEqual(wide / narrow, 440 / 375, accuracy: 0.001)
        XCTAssertLessThan(abs(narrow), abs(Slot.live.offset.x))
    }
}

extension QuickActionSlotTests {
    func testEveryFilteredArcKeepsFullTargetsAndLabelsInsidePhoneEdges() {
        let catalog = QuickActionSlot.allCases
        for mask in 1..<(1 << catalog.count) {
            let slots = catalog.enumerated().compactMap { index, slot in mask & (1 << index) != 0 ? slot : nil }
            for width in [CGFloat(375), 393, 440] {
                let plus = CGPoint(x: width / 2, y: 0)
                for (index, slot) in slots.enumerated() {
                    let point = slot.centre(plus: plus, width: width, index: index, count: slots.count)
                    XCTAssertGreaterThanOrEqual(point.x - slot.diameter / 2, QuickActionSlot.edgeMargin - 0.001)
                    XCTAssertLessThanOrEqual(point.x + slot.diameter / 2, width - QuickActionSlot.edgeMargin + 0.001)
                    let labelWidth = min(CGFloat(92), 2 * (min(point.x, width - point.x) - QuickActionSlot.edgeMargin))
                    XCTAssertGreaterThanOrEqual(labelWidth, 56, "mask \(mask), \(slot)")
                    for (otherIndex, other) in slots.enumerated() where otherIndex > index {
                        let otherPoint = other.centre(plus: plus, width: width, index: otherIndex, count: slots.count)
                        let circleGap = hypot(point.x - otherPoint.x, point.y - otherPoint.y) - (slot.diameter + other.diameter) / 2
                        XCTAssertGreaterThan(circleGap, 8, "mask \(mask), \(slot), \(other)")
                    }
                }
            }
        }
    }

    func testFilteredRecentChipClearsTheHighestVisibleCircleIncludingNoFixedActions() {
        let catalog = QuickActionSlot.allCases
        for mask in 0..<(1 << catalog.count) {
            let slots = catalog.enumerated().compactMap { index, slot in mask & (1 << index) != 0 ? slot : nil }
            let bottom = QuickActionSlot.chipOffsetY(for: slots) + 22
            XCTAssertEqual(-QuickActionSlot.topClearance(for: slots) - bottom, 14, accuracy: 0.001)
        }
    }
}
