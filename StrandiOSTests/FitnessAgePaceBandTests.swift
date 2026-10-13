import XCTest
import StrandDesign

/// A pace fitted over a few months can be absurdly steep (8 years in under 4 months is -29.2×). Beyond ±3× the
/// Fitness Age detail says "much slower/faster than typical" instead of printing the number.
final class FitnessAgePaceBandTests: XCTestCase {
    private func band(_ pace: Double) -> FitnessAgePaceRow.Band { FitnessAgePaceRow.Band(pace: pace) }

    func testAnAbsurdPaceIsNamedNotQuoted() {
        XCTAssertEqual(band(-29.2), .muchSlower)
        XCTAssertEqual(band(-3.01), .muchSlower)
        XCTAssertEqual(band(3.01), .muchFaster)
        XCTAssertEqual(band(40), .muchFaster)
        XCTAssertEqual(band(.infinity), .muchFaster)
    }

    func testThePlausibleRangeKeepsItsNumber() {
        XCTAssertEqual(band(-3), .slower)       // the limit itself still reads as a number
        XCTAssertEqual(band(0.4), .slower)
        XCTAssertEqual(band(0.96), .slower)
        XCTAssertEqual(band(0.97), .typical)
        XCTAssertEqual(band(1.0), .typical)
        XCTAssertEqual(band(1.03), .typical)
        XCTAssertEqual(band(1.04), .faster)
        XCTAssertEqual(band(3), .faster)
    }

    func testASlopeThatRoundsToNothingNeverShowsAMinusSign() {
        XCTAssertEqual(FitnessAgePaceRow.paceText(-0.04), "0.0×")
        XCTAssertEqual(FitnessAgePaceRow.paceText(-1e-17), "0.0×")
        XCTAssertEqual(FitnessAgePaceRow.paceText(-0.0), "0.0×")
        XCTAssertEqual(FitnessAgePaceRow.paceText(0.04), "0.0×")
        XCTAssertEqual(FitnessAgePaceRow.paceText(0), "0.0×")
    }

    func testARealPaceKeepsOneDecimalAndItsSign() {
        XCTAssertEqual(FitnessAgePaceRow.paceText(1.0), "1.0×")
        XCTAssertEqual(FitnessAgePaceRow.paceText(0.4), "0.4×")
        let negative = FitnessAgePaceRow.paceText(-0.4)
        XCTAssertNotEqual(negative, "0.4×")
        XCTAssertTrue(negative.hasSuffix("0.4×"), negative)
    }
}
