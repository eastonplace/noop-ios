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

    // MARK: Natural phrasing against the starter catalog

    private static let starter: [JournalEntryParser.Field] = [
        "Did you drink any alcohol?", "Did you have caffeine late in the day?", "Did you view a screen in bed?",
        "Did you eat close to bedtime?", "Did you feel stressed?", "Did you use a sauna?", "Did you share your bed?",
        "Did you feel sick or ill?", "Did you take magnesium?", "Did you read before bed?",
    ].map { JournalEntryParser.Field(canonical: $0, display: $0, kind: .boolean) }

    private func answers(_ text: String, fields: [JournalEntryParser.Field] = JournalEntryParserTests.starter)
        -> (values: [String: Bool], unmatched: [String]) {
        let draft = JournalEntryParser.parse(text, fields: fields)
        var values: [String: Bool] = [:]
        for suggestion in draft.suggestions {
            if case .boolean(let yes) = suggestion.value { values[suggestion.canonical] = yes }
        }
        return (values, draft.unmatched)
    }

    func testNaturalSentenceWithTwoBehavioursMatchesBoth() {
        let result = answers("Took magnesium before bed and felt stressed at work")

        XCTAssertEqual(result.values, ["Did you take magnesium?": true, "Did you feel stressed?": true])
        XCTAssertTrue(result.unmatched.isEmpty)
    }

    func testKeywordsAndStemsMatchAnywhereInAClause() {
        let cases: [(String, String)] = [
            ("Magnesium before bed", "Did you take magnesium?"),
            ("Super stressful day", "Did you feel stressed?"),
            ("Too much stress today", "Did you feel stressed?"),
            ("Had a couple of beers with dinner", "Did you drink any alcohol?"),
            ("A glass of wine tonight", "Did you drink any alcohol?"),
            ("Drank last night", "Did you drink any alcohol?"),
            ("Scrolling on a screen in bed", "Did you view a screen in bed?"),
            ("Ate late again", "Did you eat close to bedtime?"),
            ("Late dinner", "Did you eat close to bedtime?"),
            ("Sauna after the gym", "Did you use a sauna?"),
            ("Coffee late in the evening", "Did you have caffeine late in the day?"),
            ("Felt a bit sick", "Did you feel sick or ill?"),
            ("Read for a while in bed", "Did you read before bed?"),
        ]
        for (text, canonical) in cases {
            let result = answers(text)
            XCTAssertEqual(result.values[canonical], true, text)
        }
    }

    func testSimpleNegationIsNo() {
        let cases: [(String, String)] = [
            ("No alcohol", "Did you drink any alcohol?"),
            ("Didn't drink", "Did you drink any alcohol?"),
            ("I didn't drink last night", "Did you drink any alcohol?"),
            ("Skipped coffee this evening", "Did you have caffeine late in the day?"),
            ("Skipped my magnesium", "Did you take magnesium?"),
            ("Not stressed", "Did you feel stressed?"),
            ("Wasn't stressed at all", "Did you feel stressed?"),
            ("No sauna today", "Did you use a sauna?"),
            ("Alcohol-free night", "Did you drink any alcohol?"),
            ("No screens in bed", "Did you view a screen in bed?"),
        ]
        for (text, canonical) in cases {
            let result = answers(text)
            XCTAssertEqual(result.values[canonical], false, text)
        }
    }

    func testDrinkingSomethingElseIsNotAlcohol() {
        for text in ["Drank a lot of water", "Drank coffee all morning", "Had a drink of juice"] {
            XCTAssertNil(answers(text).values["Did you drink any alcohol?"], text)
        }
    }

    func testPlainCoffeeDoesNotAnswerTheLateCaffeineQuestion() {
        let result = answers("Had coffee in the morning")
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertEqual(result.unmatched, ["Had coffee in the morning"])
    }

    func testScreenAndBookNeedABedtimeContext() {
        for text in ["Spent all day on a screen", "Read an email from my landlord"] {
            let result = answers(text)
            XCTAssertTrue(result.values.isEmpty, text)
            XCTAssertEqual(result.unmatched, [text])
        }
    }

    func testUnsureFutureOrSomeoneElsesStatementsStayUnmatchedEvenWithAKeyword() {
        for text in ["Maybe magnesium tonight", "I will have wine tomorrow", "Should I skip alcohol?", "My wife was stressed",
                     "He drank beer", "Thinking about a sauna"] {
            let result = answers(text)
            XCTAssertTrue(result.values.isEmpty, text)
            XCTAssertEqual(result.unmatched, [text.trimmingCharacters(in: CharacterSet(charactersIn: "."))], text)
        }
    }

    func testANumberInANaturalClauseStaysVisibleBecauseTheAnswerIsOnlyYesOrNo() {
        let result = answers("Took 400 mg magnesium")

        XCTAssertEqual(result.values, ["Did you take magnesium?": true])
        XCTAssertEqual(result.unmatched, ["Took 400 mg magnesium"])
    }

    func testNaturalContradictionIsAConflictNotLastWriteWins() {
        let draft = JournalEntryParser.parse("Took magnesium before bed. Skipped my magnesium.", fields: Self.starter)

        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.conflictingFields, ["Did you take magnesium?"])
    }

    func testNaturalPhrasingNeverAnswersQuantityFields() {
        let draft = JournalEntryParser.parse("Had some coffee", fields: [caffeine])
        XCTAssertTrue(draft.suggestions.isEmpty)
        XCTAssertEqual(draft.unmatched, ["Had some coffee"])
    }
}
