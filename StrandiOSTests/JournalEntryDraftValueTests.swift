import Foundation
import XCTest
import StrandAnalytics
@testable import NOOP

final class JournalEntryDraftValueTests: XCTestCase {
    func testReviewKeepsSmallQuantityWithoutRoundingItToZero() {
        let value = 0.0000001
        let field = JournalEntryParser.Field(canonical: "Dose", display: "Dose", kind: .quantity(unit: "g"))
        let edit = JournalEntryEditableValue(field: field, suggestion: .init(canonical: "Dose", value: .quantity(value), excerpt: "Dose: 0.0000001 g"))

        XCTAssertEqual(edit.suggestion?.value, .quantity(value))
    }

    func testReviewRejectsMixedUnitsInvalidNumbersAndNumericSuffixes() {
        let field = JournalEntryParser.Field(canonical: "Caffeine", display: "Caffeine", kind: .quantity(unit: "mg"))
        var edit = JournalEntryEditableValue(field: field, suggestion: .init(canonical: "Caffeine", value: .quantity(200), excerpt: "Caffeine: 200 mg"))
        for text in ["200 mg", "2 cups", "-1", "NaN", "200x", ""] {
            edit.quantity = text
            XCTAssertNil(edit.suggestion, text)
        }
    }

    func testEditingYesToNoRemainsAnExplicitAnswer() {
        let field = JournalEntryParser.Field(canonical: "Creatine", display: "Creatine", kind: .boolean)
        var edit = JournalEntryEditableValue(field: field, suggestion: .init(canonical: "Creatine", value: .boolean(true), excerpt: "Creatine: yes"))
        edit.boolean = false
        XCTAssertEqual(edit.suggestion?.value, .boolean(false))
    }
}
