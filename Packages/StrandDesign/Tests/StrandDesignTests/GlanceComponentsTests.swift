import SwiftUI
import XCTest
@testable import StrandDesign

final class GlanceComponentsTests: XCTestCase {
    func testTheBigButtonIsATouchTargetThatDoesNotShrink() {
        XCTAssertEqual(GlanceActionButtonStyle.minimumHeight, 88)
    }

    func testAQuietReadingStepsBackLessThanAFrozenOneIsGrey() {
        XCTAssertEqual(GlanceMetricLayout.staleOpacity, 0.6, accuracy: 1e-9)
    }
}
