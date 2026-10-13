import XCTest
@testable import StrandDesign

/// The one correlation rule every screen shares: the word thresholds, the ink, and the signed text.
final class CorrelationStrengthTests: XCTestCase {
    func testThresholdsAreHalfOpenAtTheDocumentedEdges() {
        XCTAssertEqual(CorrelationStrength(r: 0), .negligible)
        XCTAssertEqual(CorrelationStrength(r: 0.094), .negligible)
        XCTAssertEqual(CorrelationStrength(r: 0.1), .weak)
        XCTAssertEqual(CorrelationStrength(r: 0.294), .weak)
        XCTAssertEqual(CorrelationStrength(r: 0.3), .moderate)
        XCTAssertEqual(CorrelationStrength(r: 0.494), .moderate)
        XCTAssertEqual(CorrelationStrength(r: 0.5), .strong)
        XCTAssertEqual(CorrelationStrength(r: 0.694), .strong)
        XCTAssertEqual(CorrelationStrength(r: 0.7), .veryStrong)
        XCTAssertEqual(CorrelationStrength(r: 1), .veryStrong)
    }

    /// The word is read off the r the screen prints: 0.4996 shows as "+0.50", so it is "strong", not "moderate".
    func testTheWordFollowsTheRoundedR() {
        XCTAssertEqual(CorrelationStrength.signedText(0.4996, locale: Locale(identifier: "en_US_POSIX")), "+0.50")
        XCTAssertEqual(CorrelationStrength(r: 0.4996), .strong)
        XCTAssertEqual(CorrelationStrength(r: -0.4996), .strong)
        XCTAssertEqual(CorrelationStrength(r: 0.2951), .moderate)
        XCTAssertEqual(CorrelationStrength(r: 0.0951), .weak)
        XCTAssertEqual(CorrelationStrength(r: 0.6951), .veryStrong)
        // Just under the rounding edge stays in the lower band.
        XCTAssertEqual(CorrelationStrength(r: 0.4949), .moderate)
        XCTAssertEqual(CorrelationStrength.tone(for: 0.2951), .positive)
    }

    func testAValueThatIsNotANumberIsNegligible() {
        XCTAssertEqual(CorrelationStrength(r: .nan), .negligible)
        XCTAssertEqual(CorrelationStrength.tone(for: .nan), .neutral)
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

    private let posix = Locale(identifier: "en_US_POSIX")

    func testSignedTextCarriesTheSignAndTwoPlaces() {
        XCTAssertEqual(CorrelationStrength.signedText(0.624, locale: posix), "+0.62")
        XCTAssertEqual(CorrelationStrength.signedText(-0.409, locale: posix), "\u{2212}0.41")
        XCTAssertEqual(CorrelationStrength.signedText(1, locale: posix), "+1.00")
    }

    func testAValueThatRoundsToZeroHasNoSign() {
        XCTAssertEqual(CorrelationStrength.signedText(0.004, locale: posix), "0.00")
        XCTAssertEqual(CorrelationStrength.signedText(-0.004, locale: posix), "0.00")
        XCTAssertEqual(CorrelationStrength.signedText(0, locale: posix), "0.00")
    }

    /// The decimal mark follows the person's locale: German uses a comma, French the same plus its own grouping.
    func testSignedTextFollowsTheLocalesDecimalMark() {
        XCTAssertEqual(CorrelationStrength.signedText(0.624, locale: Locale(identifier: "de_DE")), "+0,62")
        XCTAssertEqual(CorrelationStrength.signedText(-0.409, locale: Locale(identifier: "de_DE")), "\u{2212}0,41")
        XCTAssertEqual(CorrelationStrength.signedText(0.004, locale: Locale(identifier: "de_DE")), "0,00")
        XCTAssertEqual(CorrelationStrength.signedText(0.624, locale: Locale(identifier: "fr_FR")), "+0,62")
    }
}
