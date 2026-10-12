import SwiftUI
import XCTest
@testable import StrandDesign

final class GlancePageComponentsTests: XCTestCase {
    // MARK: Page dots

    func testPagesStopAtTheEndsInsteadOfWrapping() {
        XCTAssertEqual(PageDots.moved(0, by: -1, count: 3), 0)
        XCTAssertEqual(PageDots.moved(0, by: 1, count: 3), 1)
        XCTAssertEqual(PageDots.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(PageDots.moved(1, by: -1, count: 3), 0)
        XCTAssertEqual(PageDots.moved(5, by: 1, count: 0), 0)
    }

    func testTheSpokenPageIsOneBasedAndNamed() {
        XCTAssertEqual(PageDots.spoken(page: 1, count: 3, title: "Heart"), "Page 2 of 3, Heart")
    }
}
