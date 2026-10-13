import XCTest
import StrandDesign
import WhoopStore
@testable import NOOP

/// The Lab Book's own arithmetic and wording: day keys that never shift, dates in the person's language, tolerant number
/// entry, and sentences that follow the shared correlation rule.
final class LabBookTests: XCTestCase {
    private func row(value: Double? = nil, valueText: String? = nil, unit: String = "ng/mL", key: String = "ferritin") -> LabMarkerRow {
        LabMarkerRow(id: "t", deviceId: "d", markerKey: key, category: "bloodPanel", day: "2026-06-12", takenAt: 0,
                     value: value, valueText: valueText, unit: unit, source: "manual", note: nil, referenceText: nil)
    }

    // MARK: Day keys

    func testNoonEpochIsUTCNoonOfTheLiteralDay() throws {
        let iso = ISO8601DateFormatter()
        for day in ["2026-06-12", "2024-02-29", "2023-12-31", "1999-01-01", "2026-03-29"] {
            let expected = try XCTUnwrap(iso.date(from: "\(day)T12:00:00Z")).timeIntervalSince1970
            XCTAssertEqual(LabBookFormat.noonEpoch(day), Int(expected), day)
        }
    }

    func testNoonEpochOfAnUnreadableDayIsZeroAndNeverCollidesTwoRealDays() {
        XCTAssertEqual(LabBookFormat.noonEpoch("not a day"), 0)
        XCTAssertEqual(LabBookFormat.noonEpoch("2026-13-40"), 0)
        XCTAssertNotEqual(LabBookFormat.noonEpoch("2026-09-05"), LabBookFormat.noonEpoch("2026-09-06"))
        XCTAssertEqual(LabBookFormat.noonEpoch("2026-09-06") - LabBookFormat.noonEpoch("2026-09-05"), 86_400)
    }

    func testTheDayKeyOfADateIsItsGregorianLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 23, minute: 59))!
        XCTAssertEqual(LabBookFormat.dayKey(date), "2026-06-12")
        let early = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 1))!
        XCTAssertEqual(LabBookFormat.dayKey(early), "2026-01-01")
    }

    // MARK: Dates in the person's language

    func testADayReadsInThePersonsLanguage() {
        let en = LabBookFormat.dayFromKey("2026-06-12", locale: Locale(identifier: "en_US"))
        let fr = LabBookFormat.dayFromKey("2026-06-12", locale: Locale(identifier: "fr_FR"))
        let de = LabBookFormat.dayFromKey("2026-06-12", locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(en.contains("Jun") && en.contains("2026") && en.contains("12"), en)
        XCTAssertTrue(fr.contains("juin") && fr.contains("2026"), fr)
        XCTAssertNotEqual(en, de)
        XCTAssertTrue(de.contains("2026"), de)
    }

    func testAnUnreadableDayKeyIsShownAsItIs() {
        XCTAssertEqual(LabBookFormat.dayFromKey("someday"), "someday")
    }

    // MARK: Reading parts

    func testAReadingSplitsIntoANumberAndItsUnit() {
        let parts = LabBookFormat.parts(row(value: 92, unit: "ng/mL"), key: "ferritin")
        XCTAssertEqual(parts.unit, "ng/mL")
        XCTAssertFalse(parts.number.contains("ng"))
        XCTAssertEqual(LabBookFormat.spoken(parts), "\(parts.number) ng/mL")
    }

    func testATextEntryHasNoUnitAndAMissingReadingIsTheDash() {
        XCTAssertEqual(LabBookFormat.parts(row(valueText: "trace"), key: "x").number, "trace")
        XCTAssertEqual(LabBookFormat.parts(row(valueText: "trace"), key: "x").unit, "")
        XCTAssertEqual(LabBookFormat.parts(nil, key: "x").number, WidgetMetrics.missingValue)
        XCTAssertEqual(LabBookFormat.spoken(LabBookFormat.parts(nil, key: "x")), WidgetMetrics.missingValue)
    }

    // MARK: Number entry

    func testADecimalMarkIsTheKeyboardsOwnAndAFullStopAlwaysWorks() {
        let en = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(MarkerUnits.parse("3.1", locale: en), 3.1)
        XCTAssertEqual(MarkerUnits.parse("3,1", locale: de), 3.1)
        XCTAssertEqual(MarkerUnits.parse("3.1", locale: de), 3.1)
        XCTAssertEqual(MarkerUnits.parse(" 118 ", locale: en), 118)
        XCTAssertEqual(MarkerUnits.parse("-2,5", locale: de), -2.5)
    }

    func testAGroupingMarkIsNeverGuessedAt() {
        let en = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        XCTAssertNil(MarkerUnits.parse("3,1", locale: en))
        XCTAssertNil(MarkerUnits.parse("1,000", locale: en))
        XCTAssertNil(MarkerUnits.parse("1.234,5", locale: de))
        XCTAssertNil(MarkerUnits.parse("1,2,3", locale: de))
    }

    func testAnythingButOneNumberIsRefused() {
        XCTAssertNil(MarkerUnits.parse("", locale: Locale(identifier: "en_US")))
        XCTAssertNil(MarkerUnits.parse("abc", locale: Locale(identifier: "en_US")))
        XCTAssertNil(MarkerUnits.parse("3.1 mmol", locale: Locale(identifier: "en_US")))
    }

    // MARK: Sentences follow the shared rule

    func testASentenceIsDirectionalFromModerateUpByTheRoundedNumber() {
        let quiet = LabBookSignals.insightSentence(markerName: "LDL", signalName: "HRV", r: 0.29)
        let notable = LabBookSignals.insightSentence(markerName: "LDL", signalName: "HRV", r: 0.295)
        let falling = LabBookSignals.insightSentence(markerName: "LDL", signalName: "HRV", r: -0.6)
        XCTAssertNotEqual(quiet, notable, "0.295 prints as 0.30 and reads moderate, so it earns a directional sentence")
        XCTAssertNotEqual(notable, falling)
        XCTAssertTrue(notable.contains("LDL") && notable.contains("HRV"))
    }

    func testTheSignalNameKeepsItsCapitals() {
        let sentence = LabBookSignals.insightSentence(markerName: "LDL", signalName: "HRV", r: 0.5)
        XCTAssertTrue(sentence.contains("HRV"), sentence)
        XCTAssertFalse(sentence.contains("hrv"), sentence)
    }

    func testTheAssociationClauseNamesTheStrengthWordOfTheSharedRule() {
        for r in [0.05, 0.2, 0.4, 0.6, 0.8, -0.4] {
            let clause = LabBookSignals.associationClause(n: 9, r: r)
            XCTAssertTrue(clause.contains(CorrelationStrength(r: r).word), "r = \(r): \(clause)")
            XCTAssertTrue(clause.contains("9"), clause)
        }
    }

    func testAnUncorrelatedClauseDoesNotLeaveADoubleSpace() {
        XCTAssertFalse(LabBookSignals.associationClause(n: 9, r: 0.02).contains("  "))
    }
}
