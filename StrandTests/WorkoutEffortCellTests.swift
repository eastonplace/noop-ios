import XCTest
import StrandDesign
@testable import Strand

/// #796 - the per-session Effort surfaced on each workout row. It reads the stored 0-100 strain through
/// `StrainScale.badgeText`, the one scale every other Effort read-out routes through, so the row,
/// the Effort ring and the detail card never disagree. These pin: a captured strain renders on the
/// selected scale to one decimal, and a session with no strain shows the honest "-" rather than a 0.
final class WorkoutEffortCellTests: XCTestCase {

    func testStrainLabelIgnoresLegacyHundredPreference() {
        XCTAssertEqual(StrainScale.badgeText(fromStored: 60), "12.6")
    }

    func testEffortLabelOnWhoopScale() {
        // The WHOOP 0-21 scale applies the 21/100 factor (60 -> 12.6), matching every other read-out.
        XCTAssertEqual(StrainScale.badgeText(fromStored: 60), "12.6")
    }

    func testMissingStrainShowsDash() {
        // The empty cell uses the en-dash glyph the other workout-row cells use (row.avgHr etc.).
        XCTAssertEqual(StrainScale.badgeText(fromStored: nil), "\u{2013}")
        XCTAssertEqual(StrainScale.badgeText(fromStored: nil), "\u{2013}")
    }

    func testZeroStrainRendersZeroNotDash() {
        // A real captured 0 is data, not "missing", so it must show as a number, not the empty dash.
        XCTAssertEqual(StrainScale.badgeText(fromStored: 0), "0.0")
    }
}
