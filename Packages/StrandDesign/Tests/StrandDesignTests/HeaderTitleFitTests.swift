import SwiftUI
import XCTest
@testable import StrandDesign

#if canImport(AppKit)
import AppKit

/// A header title wraps between words and shrinks a word that is wider than the row; it never splits a word. The type
/// is measured at fixed widths through a layout probe, so the test needs no screen.
@MainActor
final class HeaderTitleFitTests: XCTestCase {
    private struct Probe: Layout {
        let width: CGFloat
        let record: @MainActor (CGSize) -> Void
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews[0].sizeThatFits(.init(width: width, height: nil))
            MainActor.assumeIsolated { record(size) }
            return size
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
    }

    private let font = Font.system(size: 40, weight: .semibold)

    private func measure<V: View>(width: CGFloat, @ViewBuilder _ view: () -> V) -> CGSize {
        var measured = CGSize.zero
        let host = NSHostingView(rootView: Probe(width: width, record: { measured = $0 }) { view() })
        _ = host.fittingSize
        return measured
    }

    private func lineHeight() -> CGFloat {
        measure(width: 2000) { Text("SUMMARY").font(font) }.height
    }

    func testAWordWiderThanTheRowIsScaledDownNotSplit() {
        let line = lineHeight()
        let wordWidth = measure(width: 2000) { Text("SUMMARY").font(font) }.width
        // 25% narrower than the word: unsplit, this would take two lines; fitted, it stays one scaled line.
        let fitted = measure(width: wordWidth * 0.75) { Text("SUMMARY").font(font).headerTitleFit() }
        XCTAssertLessThan(fitted.height, line, "one line, smaller type")
        XCTAssertLessThanOrEqual(fitted.width, wordWidth * 0.75 + 0.5)
        let split = measure(width: wordWidth * 0.75) { Text("SUMMARY").font(font).lineLimit(2) }
        XCTAssertGreaterThan(split.height, line * 1.5, "without the fit, the word is split over two lines")
    }

    func testTwoWordsWrapBetweenThemAndShrinkUntilTheLongerOneFits() {
        let line = lineHeight()
        let wordWidth = measure(width: 2000) { Text("SUMMARY").font(font) }.width
        let fitted = measure(width: wordWidth * 0.9) { Text("CYCLING SUMMARY").font(font).headerTitleFit() }
        // Two lines (one per word), each a little under full size: never three lines of split words.
        XCTAssertGreaterThan(fitted.height, line * 1.5)
        XCTAssertLessThan(fitted.height, line * 2)
    }

    func testATitleThatFitsIsLeftAlone() {
        let line = lineHeight()
        let size = measure(width: 2000) { Text("SUMMARY").font(font).headerTitleFit() }
        XCTAssertEqual(size.height, line, accuracy: 0.5)
    }
}
#endif
