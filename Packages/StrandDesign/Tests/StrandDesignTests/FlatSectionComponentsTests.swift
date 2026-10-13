import XCTest
@testable import StrandDesign

/// The pure rules behind the shared flat-section components: how a value and its unit are split, and the air a
/// separator keeps either side of its hairline.
final class FlatSectionComponentsTests: XCTestCase {
    func testValueUnitSplitSeparatesAUnitFromItsNumber() {
        let en = Locale(identifier: "en_US")
        XCTAssertTrue(ValueUnitSplit.parts("55 bpm", locale: en) == ("55", "bpm"))
        XCTAssertTrue(ValueUnitSplit.parts("7:00 AM", locale: en) == ("7:00", "AM"))
        // The narrow no-break space ICU puts before AM/PM is treated as the space it is.
        XCTAssertTrue(ValueUnitSplit.parts("7:00\u{202F}PM", locale: en) == ("7:00", "PM"))
    }

    func testValueUnitSplitKeepsCompoundsWhole() {
        let en = Locale(identifier: "en_US")
        XCTAssertTrue(ValueUnitSplit.parts("6h 49m", locale: en) == ("6h 49m", nil))
        XCTAssertTrue(ValueUnitSplit.parts("12 of 21", locale: en) == ("12 of 21", nil))
        XCTAssertTrue(ValueUnitSplit.parts("—", locale: en) == ("—", nil))
        XCTAssertTrue(ValueUnitSplit.parts("Unavailable", locale: en) == ("Unavailable", nil))
    }

    func testValueUnitSplitMatchesTheLocalesOwnDayPeriodSymbols() {
        // Spanish writes "a. m." / "p. m.", two tokens: the old "last word" rule would have cut "7:00 a." / "m.".
        let es = Locale(identifier: "es_ES")
        let formatter = DateFormatter()
        formatter.locale = es
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let am = plain(formatter.amSymbol ?? "a. m.")
        let pm = plain(formatter.pmSymbol ?? "p. m.")
        XCTAssertTrue(am.contains(" "), "Spanish day periods are multi-token; this test needs that")
        XCTAssertTrue(ValueUnitSplit.parts("7:00 \(am)", locale: es) == ("7:00", am))
        XCTAssertTrue(ValueUnitSplit.parts("11:30\u{202F}\(pm)", locale: es) == ("11:30", pm))
    }

    func testValueUnitSplitShowsNoUnitOnA24HourClock() {
        let de = Locale(identifier: "de_DE")
        XCTAssertTrue(ValueUnitSplit.parts("06:49", locale: de) == ("06:49", nil))
        XCTAssertTrue(ValueUnitSplit.parts("19:05", locale: de) == ("19:05", nil))
    }

    // MARK: Rhythm

    func testSeparatorAirIsPositive() {
        XCTAssertGreaterThan(FlatSectionRhythm.airAbove, 0)
        XCTAssertGreaterThan(FlatSectionRhythm.airBelow, 0)
        XCTAssertGreaterThan(FlatSectionRhythm.rowAir, 0)
    }
}
