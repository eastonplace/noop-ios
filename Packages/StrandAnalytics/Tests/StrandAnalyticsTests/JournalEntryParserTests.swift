import XCTest
@testable import StrandAnalytics

final class JournalEntryParserTests: XCTestCase {
    private let creatine = JournalEntryParser.Field(
        canonical: "Did you take creatine?", display: "Creatine", kind: .boolean)
    private let caffeine = JournalEntryParser.Field(
        canonical: "Caffeine (mg)", display: "Caffeine", kind: .quantity(unit: "mg"))
    private let lateCaffeine = JournalEntryParser.Field(
        canonical: "Did you have caffeine late in the day?", display: "Late caffeine", kind: .boolean)
    private let workout = JournalEntryParser.Field(
        canonical: "Did you exercise?", display: "Workout", kind: .boolean)

    func testExplicitFactsBecomeEditableSuggestionsUsingTheCatalogCanonicalKeys() {
        let draft = JournalEntryParser.parse(
            "I had 200 mg of caffeine, took creatine and worked out.",
            fields: [caffeine, creatine, workout])

        XCTAssertEqual(draft.suggestions.map(\.canonical), [caffeine.canonical, creatine.canonical, workout.canonical])
        XCTAssertEqual(draft.suggestions.map(\.value), [.quantity(200), .boolean(true), .boolean(true)])
        XCTAssertTrue(draft.unmatched.isEmpty)
    }

    /// The composer's hint offers these two phrases; they must work against the starter catalog as shipped.
    func testComposerHintExamplesMatchTheStarterCatalog() {
        let fields = ["Did you take magnesium?", "Did you feel stressed?", "Did you drink any alcohol?"].map {
            JournalEntryParser.Field(canonical: $0, display: $0, kind: .boolean)
        }
        let draft = JournalEntryParser.parse("I took magnesium and I felt stressed.", fields: fields)

        XCTAssertEqual(draft.suggestions.map(\.canonical), ["Did you take magnesium?", "Did you feel stressed?"])
        XCTAssertEqual(draft.suggestions.map(\.value), [.boolean(true), .boolean(true)])
        XCTAssertTrue(draft.unmatched.isEmpty)
    }

    func testAbsenceRemainsUnansweredAndExplicitNegationIsNo() {
        let draft = JournalEntryParser.parse("I did not take creatine.", fields: [creatine, caffeine, workout])

        XCTAssertEqual(draft.suggestions.count, 1)
        XCTAssertEqual(draft.suggestions.first?.value, .boolean(false))
        XCTAssertEqual(draft.suggestions.first?.canonical, creatine.canonical)
    }

    func testGenericCaffeineDoesNotAnswerTheLateCaffeineQuestionEvenAfterRename() {
        let renamed = JournalEntryParser.Field(canonical: lateCaffeine.canonical, display: "Caffeine", kind: .boolean)
        let draft = JournalEntryParser.parse("I had coffee.", fields: [renamed])

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["I had coffee"])
    }

    func testExplicitLateCaffeineAnswersTheTimingQuestion() {
        let draft = JournalEntryParser.parse("I had caffeine late in the day.", fields: [lateCaffeine])

        XCTAssertEqual(draft.suggestions.first?.value, .boolean(true))
    }

    func testCoffeeQuantityNeverInventsCaffeineMilligrams() {
        let draft = JournalEntryParser.parse("I had two cups of coffee.", fields: [caffeine, lateCaffeine])

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["I had two cups of coffee"])
    }

    func testExplicitCupsMatchOnlyACatalogWithCupUnits() {
        let cups = JournalEntryParser.Field(canonical: "Caffeine (cups)", display: "Coffee cups", kind: .quantity(unit: "cups"))
        let draft = JournalEntryParser.parse("I had two cups of coffee.", fields: [cups, lateCaffeine])

        XCTAssertEqual(draft.suggestions.count, 1)
        XCTAssertEqual(draft.suggestions.first?.canonical, cups.canonical)
        XCTAssertEqual(draft.suggestions.first?.value, .quantity(2))
    }

    func testExplicitCompatibleUnitsConvertWithoutGuessing() {
        let draft = JournalEntryParser.parse("Caffeine: 0.2 g.", fields: [caffeine])

        XCTAssertEqual(draft.suggestions.first?.value, .quantity(200))
        XCTAssertTrue(draft.unmatched.isEmpty)
    }

    func testMissingWrongNegativeAndNonFiniteQuantitiesRemainUnmatched() {
        for input in ["Caffeine: 200", "Caffeine: 2 cups", "Caffeine: -20 mg", "Caffeine: nan mg", "Caffeine: 1e309 mg"] {
            let draft = JournalEntryParser.parse(input, fields: [caffeine])
            XCTAssertTrue(draft.suggestions.isEmpty, input)
            XCTAssertFalse(draft.unmatched.isEmpty, input)
        }
    }

    func testCustomLabelsRequireAnExplicitValueAndPreserveTheirOriginalKeys() {
        let custom = JournalEntryParser.Field(canonical: "Original custom question", display: "Cold plunge", kind: .boolean)
        let explicit = JournalEntryParser.parse("Cold plunge: no", fields: [custom])
        let narrative = JournalEntryParser.parse("I did a cold plunge", fields: [custom])

        XCTAssertEqual(explicit.suggestions.first?.canonical, "Original custom question")
        XCTAssertEqual(explicit.suggestions.first?.value, .boolean(false))
        XCTAssertTrue(narrative.suggestions.isEmpty)
        XCTAssertFalse(narrative.unmatched.isEmpty)
    }

    func testContradictoryStatementsRemainUnmatchedInsteadOfLastWriteWins() {
        let draft = JournalEntryParser.parse("I took creatine and I did not take creatine.", fields: [creatine])

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.conflictingFields, [creatine.canonical])
        XCTAssertEqual(draft.unmatched.count, 2)
    }

    func testRepeatedSameAnswerProducesOneSuggestion() {
        let draft = JournalEntryParser.parse("I took creatine. Creatine: yes.", fields: [creatine])

        XCTAssertEqual(draft.suggestions.count, 1)
        XCTAssertTrue(draft.conflictingFields.isEmpty)
    }

    func testAmbiguousCatalogDoesNotChooseAnArbitraryField() {
        let other = JournalEntryParser.Field(canonical: "Creatine", display: "Creatine supplement", kind: .boolean)
        let draft = JournalEntryParser.parse("I took creatine.", fields: [creatine, other])

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["I took creatine"])
    }

    func testMoodFutureUncertaintyAndOtherPeoplesActionsAreNotInventedAnswers() {
        for input in ["I felt great", "I might take creatine", "I will take creatine", "My partner took creatine", "I forgot whether I took creatine"] {
            let draft = JournalEntryParser.parse(input, fields: [creatine, workout])
            XCTAssertTrue(draft.suggestions.isEmpty, input)
            XCTAssertFalse(draft.unmatched.isEmpty, input)
        }
    }

    func testQuestionAboutAnActionDoesNotBecomeAnAffirmativeAnswer() {
        let draft = JournalEntryParser.parse("I took creatine?", fields: [creatine])
        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["I took creatine?"])
    }

    func testQuestionAboutAnExplicitValueAlsoRemainsUnmatched() {
        let draft = JournalEntryParser.parse("Creatine: yes?", fields: [creatine])
        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["Creatine: yes?"])
    }

    func testWorkoutDetailsRemainVisibleWithoutCreatingDetailedWorkoutFacts() {
        let draft = JournalEntryParser.parse("I ran for 45 minutes.", fields: [workout])

        XCTAssertEqual(draft.suggestions.first?.value, .boolean(true))
        XCTAssertEqual(draft.unmatched, ["I ran for 45 minutes"])
    }

    func testFactsNotInTheCatalogRemainUnmatched() {
        let draft = JournalEntryParser.parse("I took creatine. I felt happy.", fields: [caffeine])

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["I took creatine", "I felt happy"])
    }

    func testOversizedInputIsRejectedAsAWholeWithoutSavingAPartialInterpretation() {
        let input = "I took creatine. " + String(repeating: "x", count: JournalEntryParser.maximumInputBytes)
        let draft = JournalEntryParser.parse(input, fields: [creatine])

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertTrue(draft.exceedsLimit)
        XCTAssertEqual(draft.unmatched, [input])
    }

    func testNumericZeroIsAnExplicitQuantityAndNeverAMissingAnswer() {
        let draft = JournalEntryParser.parse("Caffeine: 0 mg", fields: [caffeine])
        XCTAssertEqual(draft.suggestions.first?.value, .quantity(0))
    }
}
