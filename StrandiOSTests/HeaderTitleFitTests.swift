import SwiftUI
import UIKit
import XCTest
import StrandDesign

/// On a device SwiftUI hyphenates a header title's long word ("ANSTREN-GUNG") when the type is a Dynamic Type text
/// style; the header title instead scales it to fit. Measured through a hosting controller at the largest text size.
@MainActor
final class HeaderTitleFitTests: XCTestCase {
    private func height<V: View>(width: CGFloat, @ViewBuilder _ view: () -> V) -> CGFloat {
        UIHostingController(rootView: view().environment(\.dynamicTypeSize, .accessibility5))
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }

    func testALongWordInThePushedRowStaysOnOneScaledLine() {
        let oneLine = height(width: 3000) { NoopDetailTitleRow("Anstrengung", backAction: {}) }
        let narrow = height(width: 300) { NoopDetailTitleRow("Anstrengung", backAction: {}) }
        XCTAssertLessThan(narrow, oneLine * 1.4, "a hyphenated word would stack two title lines")
    }

    func testTwoWordsWrapBetweenThemInThePushedRow() {
        let oneLine = height(width: 3000) { NoopDetailTitleRow("Cycling Summary", backAction: {}) }
        let narrow = height(width: 300) { NoopDetailTitleRow("Cycling Summary", backAction: {}) }
        // Two lines (one per word), never three of split words.
        XCTAssertLessThan(narrow, oneLine * 2.4)
    }

    func testTheCompactSheetHeaderAndTheTabRowDoNotStackSplitWordsEither() {
        let oneLine = height(width: 3000) { NoopTabTitleRow("Anstrengung") }
        let tab = height(width: 300) { NoopTabTitleRow("Anstrengung") }
        XCTAssertLessThan(tab, oneLine * 1.4)
        let headerOneLine = height(width: 3000) { NoopScreenHeader(title: "Anstrengung", style: .compact) }
        let header = height(width: 300) { NoopScreenHeader(title: "Anstrengung", style: .compact) }
        XCTAssertLessThan(header, headerOneLine * 1.4)
    }
}
