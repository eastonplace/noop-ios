import XCTest
@testable import StrandDesign

/// The one correlation rule every screen shares: the word thresholds, the ink, and the signed text.
final class CorrelationStrengthTests: XCTestCase {
    func testThresholdsAreHalfOpenAtTheDocumentedEdges() {
        XCTAssertEqual(CorrelationStrength(r: 0), .negligible)
        XCTAssertEqual(CorrelationStrength(r: 0.099), .negligible)
        XCTAssertEqual(CorrelationStrength(r: 0.1), .weak)
        XCTAssertEqual(CorrelationStrength(r: 0.299), .weak)
        XCTAssertEqual(CorrelationStrength(r: 0.3), .moderate)
        XCTAssertEqual(CorrelationStrength(r: 0.499), .moderate)
        XCTAssertEqual(CorrelationStrength(r: 0.5), .strong)
        XCTAssertEqual(CorrelationStrength(r: 0.699), .strong)
        XCTAssertEqual(CorrelationStrength(r: 0.7), .veryStrong)
        XCTAssertEqual(CorrelationStrength(r: 1), .veryStrong)
    }

    func testStrengthIgnoresTheSignOfR() {
        for magnitude in [0.05, 0.2, 0.4, 0.6, 0.9] {
            XCTAssertEqual(CorrelationStrength(r: magnitude), CorrelationStrength(r: -magnitude))
        }
    }

    func testOnlyAModerateOrStrongerRelationshipIsDrawnInColour() {
        XCTAssertEqual(CorrelationStrength.tone(for: 0.05), .neutral)
        XCTAssertEqual(CorrelationStrength.tone(for: -0.29), .neutral)
        XCTAssertEqual(CorrelationStrength.tone(for: 0.3), .positive)
        XCTAssertEqual(CorrelationStrength.tone(for: 0.95), .positive)
        XCTAssertEqual(CorrelationStrength.tone(for: -0.3), .critical)
        XCTAssertEqual(CorrelationStrength.tone(for: -0.95), .critical)
    }

    func testColourFollowsTheTone() {
        XCTAssertEqual(CorrelationStrength.color(for: 0.6), StrandTone.positive.color)
        XCTAssertEqual(CorrelationStrength.color(for: -0.6), StrandTone.critical.color)
        XCTAssertEqual(CorrelationStrength.color(for: 0.1), StrandTone.neutral.color)
    }

    func testSignedTextCarriesTheSignAndTwoPlaces() {
        XCTAssertEqual(CorrelationStrength.signedText(0.624), "+0.62")
        XCTAssertEqual(CorrelationStrength.signedText(-0.409), "\u{2212}0.41")
        XCTAssertEqual(CorrelationStrength.signedText(1), "+1.00")
    }

    func testAValueThatRoundsToZeroHasNoSign() {
        XCTAssertEqual(CorrelationStrength.signedText(0.004), "0.00")
        XCTAssertEqual(CorrelationStrength.signedText(-0.004), "0.00")
        XCTAssertEqual(CorrelationStrength.signedText(0), "0.00")
    }
}
