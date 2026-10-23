import XCTest
@testable import StrandAnalytics

final class JournalAssociationAnalysisTests: XCTestCase {
    private let question = "Did you take magnesium?"
    private let native = "journal-native"

    func testExplicitAnswersMatchOnlySameWakeDayRecoveryAndMissingIsNotNo() throws {
        let answers = [
            answer(1, true), answer(2, true), answer(3, true), answer(4, false),
            answer(5, false), answer(6, false), answer(7, true)
        ]
        let result = analyze(answers, recovery: [
            recovery(1, 80), recovery(2, 70), recovery(3, 90),
            recovery(4, 50), recovery(5, 60), recovery(6, 70),
            recovery(8, 100)
        ])
        let insight = try XCTUnwrap(result.first)

        XCTAssertEqual(insight.state, .available)
        XCTAssertEqual(insight.matchedYesCount, 3)
        XCTAssertEqual(insight.matchedNoCount, 3)
        XCTAssertEqual(insight.loggedYesCount, 4)
        XCTAssertEqual(insight.loggedNoCount, 3, "Unlogged day 8 must not become an explicit no")
        XCTAssertEqual(insight.missingRecoveryCount, 1)
        XCTAssertEqual(insight.yesMean, 80)
        XCTAssertEqual(insight.noMean, 60)
        XCTAssertEqual(insight.difference, 20)
        XCTAssertEqual(insight.windowFrom, "2026-10-01")
        XCTAssertEqual(insight.windowThrough, "2026-10-10")
        XCTAssertEqual(insight.latestDay, "2026-10-07")
        XCTAssertEqual(insight.sources, [native])
        XCTAssertEqual(insight.recoverySource, "canonical-test")
    }

    func testThreeMatchedDaysAreRequiredInBothGroupsBeforeAnyAverageIsPublished() throws {
        let insight = try XCTUnwrap(analyze(sixAnswers, recovery: (1...5).map { recovery($0, 70) }).first)

        XCTAssertEqual(insight.state, .insufficientData)
        XCTAssertEqual(insight.matchedYesCount, 3)
        XCTAssertEqual(insight.matchedNoCount, 2)
        XCTAssertEqual(insight.missingRecoveryCount, 1)
        XCTAssertNil(insight.yesMean)
        XCTAssertNil(insight.noMean)
        XCTAssertNil(insight.difference)
    }

    func testAnyNumericValuedQuestionIsExcludedRatherThanInterpretedAsBoolean() throws {
        let insight = try XCTUnwrap(analyze(sixAnswers + [answer(7, true, numeric: 0)],
                                          recovery: completeRecovery).first)

        XCTAssertEqual(insight.state, .noBooleanAnswers)
        XCTAssertEqual(insight.excludedNumericAnswerCount, 7)
        XCTAssertNil(insight.question)
        XCTAssertNil(insight.difference)
    }

    func testCatalogDeclaredNumericQuestionCannotReuseItsOldBooleanEncoding() throws {
        let insight = try XCTUnwrap(analyze(reads: [read(native, sixAnswers)], numericQuestions: [question]).first)

        XCTAssertEqual(insight.state, .noBooleanAnswers)
        XCTAssertEqual(insight.excludedNumericAnswerCount, 6)
        XCTAssertNil(insight.yesMean)
    }

    func testNativeAnswersOverrideImportsByCatalogIdentityBeforeGrouping() throws {
        let imported = read("imported", (1...6).map { answer($0, true) })
        let local = read(native, (4...6).map { answer($0, false, question: " DID YOU TAKE  MAGNESIUM?\n") })
        let first = analyze(reads: [local, imported])
        let reversed = analyze(reads: [imported, local])
        let insight = try XCTUnwrap(first.first)

        XCTAssertEqual(first, reversed, "Source read order cannot select answers")
        XCTAssertEqual(insight.state, .available)
        XCTAssertEqual(insight.loggedYesCount, 3)
        XCTAssertEqual(insight.loggedNoCount, 3)
        XCTAssertEqual(insight.sources, ["imported", native])
    }

    func testConflictingImportedAnswersAreExcludedUnlessNativeAnswerResolvesThem() throws {
        let imports = [read("import-a", sixAnswers), read("import-b", [answer(1, false)])]
        let unresolved = try XCTUnwrap(analyze(reads: imports).first)
        let resolved = try XCTUnwrap(analyze(reads: imports + [read(native, [answer(1, true)])]).first)

        XCTAssertEqual(unresolved.state, .insufficientData)
        XCTAssertEqual(unresolved.matchedYesCount, 2)
        XCTAssertEqual(unresolved.conflictingDayCount, 1)
        XCTAssertNil(unresolved.difference)
        XCTAssertEqual(resolved.state, .available)
        XCTAssertEqual(resolved.matchedYesCount, 3)
        XCTAssertEqual(resolved.conflictingDayCount, 0)
    }

    func testIdenticalAnswersAcrossSourcesCountOncePerWakeDay() throws {
        let insight = try XCTUnwrap(analyze(reads: [read("import-a", sixAnswers), read("import-b", sixAnswers)]).first)

        XCTAssertEqual(insight.matchedYesCount, 3)
        XCTAssertEqual(insight.matchedNoCount, 3)
        XCTAssertEqual(insight.sources, ["import-a", "import-b"])
    }

    func testAnyTruncatedSourceSuppressesMetricsAndPotentiallyBiasedMergedCounts() throws {
        for source in [native, "import-a"] {
            let insight = try XCTUnwrap(analyze(reads: [
                read("import-b", sixAnswers),
                .init(source: source, answers: [answer(1, false)], isTruncated: true)
            ]).first)

            XCTAssertEqual(insight.state, .truncated)
            XCTAssertEqual(insight.truncatedSources, [source])
            XCTAssertNil(insight.question)
            XCTAssertNil(insight.loggedYesCount)
            XCTAssertNil(insight.loggedNoCount)
            XCTAssertNil(insight.matchedYesCount)
            XCTAssertNil(insight.matchedNoCount)
            XCTAssertNil(insight.missingRecoveryCount)
            XCTAssertNil(insight.yesMean)
            XCTAssertNil(insight.noMean)
            XCTAssertNil(insight.difference)
        }
    }

    func testNinetyDayWindowWithFourHabitsRemainsACompleteComparison() {
        let fixture = history(habits: 4, days: 90)
        let insights = JournalAssociationAnalysis.analyze(
            reads: [read(native, fixture.answers)], recovery: fixture.recovery,
            nativeSource: native, recoverySource: "canonical-test",
            windowFrom: fixture.from, windowThrough: fixture.through)

        XCTAssertEqual(fixture.answers.count, 360)
        XCTAssertEqual(insights.count, 4)
        for insight in insights {
            XCTAssertEqual(insight.state, .available)
            XCTAssertEqual(insight.matchedYesCount, 45)
            XCTAssertEqual(insight.matchedNoCount, 45)
            XCTAssertEqual(insight.difference, 20)
        }
    }

    func testExact4096RowReadIsCompleteWhenThereIsNoOverflowSentinel() {
        let fixture = history(habits: 64, days: 64)
        let source = read(native, fixture.answers)
        let insights = JournalAssociationAnalysis.analyze(
            reads: [source], recovery: fixture.recovery, nativeSource: native,
            recoverySource: "canonical-test", windowFrom: fixture.from, windowThrough: fixture.through)

        XCTAssertEqual(JournalAssociationAnalysis.maximumRowsPerSource, 4_096)
        XCTAssertEqual(source.answers.count, 4_096)
        XCTAssertFalse(source.isTruncated)
        XCTAssertEqual(insights.count, 64)
        XCTAssertTrue(insights.allSatisfy { $0.state == .available && $0.difference == 20 })
    }

    func testOverflowSentinelIsRemovedAndSuppressesAllCountsAndEffects() throws {
        let fixture = history(habits: 64, days: 64)
        let sentinel = JournalAssociationAnalysis.Answer(day: fixture.from, question: "Overflow sentinel", answeredYes: false)
        let source = read(native, fixture.answers + [sentinel])
        let insight = try XCTUnwrap(JournalAssociationAnalysis.analyze(
            reads: [source], recovery: fixture.recovery, nativeSource: native,
            recoverySource: "canonical-test", windowFrom: fixture.from, windowThrough: fixture.through).first)

        XCTAssertTrue(source.isTruncated)
        XCTAssertEqual(source.answers.count, 4_096)
        XCTAssertFalse(source.answers.contains(sentinel), "The extra row only proves overflow; it is never analyzed")
        XCTAssertEqual(insight.state, .truncated)
        XCTAssertEqual(insight.truncatedSources, [native])
        XCTAssertNil(insight.loggedYesCount)
        XCTAssertNil(insight.loggedNoCount)
        XCTAssertNil(insight.matchedYesCount)
        XCTAssertNil(insight.matchedNoCount)
        XCTAssertNil(insight.missingRecoveryCount)
        XCTAssertNil(insight.yesMean)
        XCTAssertNil(insight.noMean)
        XCTAssertNil(insight.difference)
    }

    func testNativeNumericValueCannotFallBackToImportedBooleanAnswer() throws {
        let insight = try XCTUnwrap(analyze(reads: [
            read("imported", sixAnswers), read(native, [answer(1, true, numeric: 200)])
        ]).first)

        XCTAssertEqual(insight.state, .noBooleanAnswers)
        XCTAssertNil(insight.difference)
    }

    func testInvalidAndAbsentRecoveryAreMissingOutcomesNotZeroes() throws {
        let invalid: [Double?] = [nil, .nan, .infinity, -1, 101, nil]
        let insight = try XCTUnwrap(analyze(sixAnswers, recovery: invalid.enumerated().map {
            recovery($0.offset + 1, $0.element)
        }).first)

        XCTAssertEqual(insight.state, .insufficientData)
        XCTAssertEqual(insight.matchedYesCount, 0)
        XCTAssertEqual(insight.matchedNoCount, 0)
        XCTAssertEqual(insight.missingRecoveryCount, 6)
        XCTAssertNil(insight.difference)
    }

    func testConflictingCanonicalRecoveryDuplicatesAreNotArbitrarilySelected() throws {
        let insight = try XCTUnwrap(analyze(sixAnswers, recovery: completeRecovery + [recovery(1, 99)]).first)

        XCTAssertEqual(insight.state, .insufficientData)
        XCTAssertEqual(insight.matchedYesCount, 2)
        XCTAssertEqual(insight.missingRecoveryCount, 1)
    }

    func testOutOfWindowAndInvalidCivilDatesDoNotEnterTheSample() throws {
        let insight = try XCTUnwrap(JournalAssociationAnalysis.analyze(
            reads: [read(native, [
                .init(day: "2026-02-30", question: question, answeredYes: true),
                .init(day: "2026-03-01", question: question, answeredYes: false),
                .init(day: "2026-03-11", question: question, answeredYes: true)
            ])],
            recovery: [], nativeSource: native, recoverySource: "canonical-test",
            windowFrom: "2026-02-01", windowThrough: "2026-03-10").first)

        XCTAssertEqual(insight.loggedYesCount, 0)
        XCTAssertEqual(insight.loggedNoCount, 1)
        XCTAssertEqual(insight.latestDay, "2026-03-01")
    }

    func testEmptyWindowProducesAnHonestDataStateAndCodableRoundTrip() throws {
        let insights = analyze(reads: [read(native, [])])
        let insight = try XCTUnwrap(insights.first)

        XCTAssertEqual(insight.state, .noBooleanAnswers)
        XCTAssertEqual(insight.matchedYesCount, 0)
        XCTAssertEqual(insight.sourcesRead, [native])
        XCTAssertNil(insight.latestDay)
        XCTAssertNil(insight.yesMean)
        XCTAssertEqual(try JSONDecoder().decode([JournalAssociationAnalysis.Insight].self,
                                               from: JSONEncoder().encode(insights)), insights)
    }

    private var sixAnswers: [JournalAssociationAnalysis.Answer] { (1...6).map { answer($0, $0 <= 3) } }
    private var completeRecovery: [JournalAssociationAnalysis.Recovery] { (1...7).map { recovery($0, Double(50 + $0)) } }

    private func history(habits: Int, days: Int) -> (answers: [JournalAssociationAnalysis.Answer],
                                                   recovery: [JournalAssociationAnalysis.Recovery],
                                                   from: String, through: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let dates = (0..<days).map { formatter.string(from: calendar.date(byAdding: .day, value: $0, to: start)!) }
        let answers = dates.enumerated().flatMap { index, day in
            (0..<habits).map { habit in
                JournalAssociationAnalysis.Answer(day: day, question: "Habit \(habit)", answeredYes: index.isMultiple(of: 2))
            }
        }
        let recovery = dates.enumerated().map { index, day in
            JournalAssociationAnalysis.Recovery(day: day, value: index.isMultiple(of: 2) ? 80 : 60)
        }
        return (answers, recovery, dates.first!, dates.last!)
    }

    private func read(_ source: String, _ answers: [JournalAssociationAnalysis.Answer]) -> JournalAssociationAnalysis.SourceRead {
        .init(source: source, answers: answers, isTruncated: false)
    }

    private func analyze(reads: [JournalAssociationAnalysis.SourceRead],
                         numericQuestions: Set<String> = []) -> [JournalAssociationAnalysis.Insight] {
        JournalAssociationAnalysis.analyze(
            reads: reads, recovery: completeRecovery, nativeSource: native, recoverySource: "canonical-test",
            windowFrom: "2026-10-01", windowThrough: "2026-10-10", numericQuestions: numericQuestions)
    }

    private func answer(_ day: Int, _ yes: Bool, question: String? = nil,
                        numeric: Double? = nil) -> JournalAssociationAnalysis.Answer {
        .init(day: key(day), question: question ?? self.question, answeredYes: yes, numericValue: numeric)
    }

    private func recovery(_ day: Int, _ value: Double?) -> JournalAssociationAnalysis.Recovery {
        .init(day: key(day), value: value)
    }

    private func key(_ day: Int) -> String { String(format: "2026-10-%02d", day) }

    private func analyze(_ answers: [JournalAssociationAnalysis.Answer],
                         recovery: [JournalAssociationAnalysis.Recovery]) -> [JournalAssociationAnalysis.Insight] {
        JournalAssociationAnalysis.analyze(
            reads: [.init(source: native, answers: answers, isTruncated: false)],
            recovery: recovery, nativeSource: native, recoverySource: "canonical-test",
            windowFrom: "2026-10-01", windowThrough: "2026-10-10")
    }
}
