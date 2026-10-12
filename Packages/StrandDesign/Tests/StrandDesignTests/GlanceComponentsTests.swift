import SwiftUI
import XCTest
@testable import StrandDesign

final class GlanceComponentsTests: XCTestCase {
    func testTheFocusNumeralStepsDownAsItGainsCharacters() {
        // "9.99" -> "10.00" km and "59:59" -> "1:00:00" must step down, never overflow the line.
        XCTAssertEqual(GlanceMetricLayout.focusPointSize(characterCount: 1), 132)
        XCTAssertEqual(GlanceMetricLayout.focusPointSize(characterCount: 4), 132)
        XCTAssertEqual(GlanceMetricLayout.focusPointSize(characterCount: 5), 116)
        XCTAssertEqual(GlanceMetricLayout.focusPointSize(characterCount: 6), 100)
        XCTAssertEqual(GlanceMetricLayout.focusPointSize(characterCount: 7), 80)
        XCTAssertEqual(GlanceMetricLayout.focusPointSize(characterCount: 12), 80)
    }

    func testTheSizeNeverGrowsWithMoreCharacters() {
        var previous = CGFloat.infinity
        for count in 0...12 {
            let size = GlanceMetricLayout.focusPointSize(characterCount: count)
            XCTAssertLessThanOrEqual(size, previous, "\(count) characters")
            previous = size
        }
    }

    func testEveryFocusSizeIsLargerThanTheSecondaryNumeral() {
        XCTAssertEqual(GlanceMetricLayout.secondaryPointSize, 56)
        for count in 0...12 {
            XCTAssertGreaterThan(GlanceMetricLayout.focusPointSize(characterCount: count),
                                 GlanceMetricLayout.secondaryPointSize)
        }
    }

    func testTheBigButtonIsATouchTargetThatDoesNotShrink() {
        XCTAssertEqual(GlanceActionButtonStyle.minimumHeight, 88)
    }
}
