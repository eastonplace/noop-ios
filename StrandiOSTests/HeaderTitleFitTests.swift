import SwiftUI
import UIKit
import XCTest
@testable import NOOP
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

    func testASectionEyebrowScalesALongWordInsteadOfHyphenatingIt() {
        let oneLine = height(width: 3000) { SectionEyebrow(title: "Tagesanstrengung") }
        let narrow = height(width: 280) { SectionEyebrow(title: "Tagesanstrengung") }
        XCTAssertLessThan(narrow, oneLine * 1.4, "a hyphenated word would stack two lines")
    }

    func testTheExpandedScreenTitleScalesALongWordInsteadOfHyphenatingIt() {
        let oneLine = height(width: 3000) { NoopScreenHeader(title: "Anstrengung") }
        let narrow = height(width: 320) { NoopScreenHeader(title: "Anstrengung") }
        XCTAssertLessThan(narrow, oneLine * 1.3)
    }

    func testTheCompactHeaderSubtitleWrapsUnderTheTitleInsteadOfTruncating() {
        let subtitle: LocalizedStringKey = "Erholung · Anstrengung · Schlaf · Gesundheit"
        let oneLine = height(width: 3000) { NoopScreenHeader(title: "Wert", subtitle: subtitle, style: .compact) }
        let narrow = height(width: 300) { NoopScreenHeader(title: "Wert", subtitle: subtitle, style: .compact) }
        XCTAssertGreaterThan(narrow, oneLine * 1.3, "the subtitle takes more lines rather than ending in an ellipsis")
    }

    func testATabLabelStaysOnOneLineAtTheLargestTextSize() {
        let word = height(width: 3000) { PaperTabLabel(title: "Einstellungen", isActive: false) }
        let slot = height(width: 60) { PaperTabLabel(title: "Einstellungen", isActive: true) }
        // Scaled down to fit the slot it is shorter than the full-size line; wrapped or hyphenated it would be taller.
        XCTAssertLessThanOrEqual(slot, word + 1, "a label that did not fit would wrap or hyphenate onto a second line")
    }
}
