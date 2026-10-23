import XCTest
import SwiftUI
import WhoopStore
@testable import NOOP

/// The rules of the one-page Journal grid: what a tap does, how an amount reads, which answers "Mark the rest No"
/// writes, and how an imported answer and a tap combine into the one answer the page shows.
final class JournalQuickLogTests: XCTestCase {
    private typealias Q = JournalQuickLog

    // MARK: Tap cycle

    func testTapGoesYesThenNoThenYesAndNeverBackToBlank() {
        var answer: Bool?
        var seen: [Bool] = []
        for _ in 0..<5 {
            let next = Q.tapped(answer)
            seen.append(next)
            answer = next
        }
        XCTAssertEqual(seen, [true, false, true, false, true])
    }

    func testAmountStepsUpByItsStepAndDownToAnExplicitZero() {
        XCTAssertEqual(Q.stepUp(nil, step: 1), 1)
        XCTAssertEqual(Q.stepUp(1, step: 1), 2)
        XCTAssertEqual(Q.stepUp(nil, step: 10), 10)
        XCTAssertEqual(Q.stepUp(20, step: 10), 30)
        XCTAssertEqual(Q.stepDown(2, step: 1), 1)
        XCTAssertEqual(Q.stepDown(1, step: 1), 0, "Stepping down at 1 saves an explicit zero")
        XCTAssertEqual(Q.stepDown(10, step: 10), 0)
        XCTAssertEqual(Q.stepDown(5, step: 10), 0, "A step never goes below zero")
        XCTAssertNil(Q.stepDown(0, step: 1), "Nothing to take off at zero")
        XCTAssertNil(Q.stepDown(nil, step: 1))
    }

    // MARK: Amount text

    func testAmountsReadWithTheirUnitAgreeingWithTheNumber() {
        let drinks = Q.Unit(singular: "drink", plural: "drinks")
        XCTAssertEqual(Q.amountText(1, unit: drinks), "1 drink")
        XCTAssertEqual(Q.amountText(2, unit: drinks), "2 drinks")
        XCTAssertEqual(Q.amountText(0.5, unit: drinks), "0.5 drinks")
        XCTAssertEqual(Q.amountText(1, unit: Q.Unit(singular: "dose", plural: "doses")), "1 dose")
        XCTAssertEqual(Q.amountText(20, unit: Q.fixedUnit("min")), "20 min")
        XCTAssertEqual(Q.amountText(1, unit: Q.fixedUnit("min")), "1 min")
    }

    func testCatalogUnitsGetASingularOnlyWhenKnown() {
        XCTAssertEqual(Q.amountText(1, unit: Q.catalogUnit("units")), "1 unit")
        XCTAssertEqual(Q.amountText(3, unit: Q.catalogUnit("units")), "3 units")
        XCTAssertEqual(Q.amountText(1, unit: Q.catalogUnit("glasses")), "1 glass")
        XCTAssertEqual(Q.amountText(1, unit: Q.catalogUnit("mg")), "1 mg")
        XCTAssertEqual(Q.amountText(200, unit: Q.catalogUnit("mg")), "200 mg")
    }

    func testStarterQuestionsStepAndPluralizeAsSpecified() throws {
        func item(_ question: String) -> JournalCatalogItem {
            JournalCatalogItem(canonical: question, displayName: nil, kind: .bool, group: .other,
                               sortIndex: 0, hidden: false, custom: false)
        }
        let alcohol = try XCTUnwrap(coachingQuantity(for: item("Did you drink any alcohol?")))
        XCTAssertEqual(alcohol.step, 1)
        XCTAssertEqual(Q.amountText(1, unit: alcohol.unit), "1 drink")
        XCTAssertEqual(Q.amountText(2, unit: alcohol.unit), "2 drinks")
        let caffeine = try XCTUnwrap(coachingQuantity(for: item("Did you have caffeine late in the day?")))
        XCTAssertEqual(caffeine.step, 1)
        let magnesium = try XCTUnwrap(coachingQuantity(for: item("Did you take magnesium?")))
        XCTAssertEqual(magnesium.step, 1)
        XCTAssertEqual(Q.amountText(1, unit: magnesium.unit), "1 dose")
        let sauna = try XCTUnwrap(coachingQuantity(for: item("Did you use a sauna?")))
        XCTAssertEqual(sauna.step, 10)
        XCTAssertEqual(Q.amountText(20, unit: sauna.unit), "20 min")
        XCTAssertNil(coachingQuantity(for: item("Did you read before bed?")))
    }

    func testStateTextIsEmptyUntilAnsweredThenYesNoOrTheAmount() {
        let unit = Q.Unit(singular: "drink", plural: "drinks")
        XCTAssertEqual(Q.stateText(.unanswered, unit: nil), "")
        XCTAssertEqual(Q.stateText(.yes, unit: nil), "Yes")
        XCTAssertEqual(Q.stateText(.no, unit: nil), "No")
        XCTAssertEqual(Q.stateText(.amount(2), unit: unit), "2 drinks")
        XCTAssertEqual(Q.stateText(.no, unit: unit), "No", "A counted question at zero reads as No")
    }

    // MARK: State

    func testStateReadsFromTheAnswerOrTheAmount() {
        let values = Q.DayValues(answers: ["bed": true, "late": false, "beer": true, "tea": false, "wine": true],
                                 numeric: ["beer": 2, "tea": 0])
        XCTAssertEqual(Q.state(of: "bed", hasAmount: false, in: values), .yes)
        XCTAssertEqual(Q.state(of: "late", hasAmount: false, in: values), .no)
        XCTAssertEqual(Q.state(of: "beer", hasAmount: true, in: values), .amount(2))
        XCTAssertEqual(Q.state(of: "tea", hasAmount: true, in: values), .no)
        XCTAssertEqual(Q.state(of: "wine", hasAmount: true, in: values), .yes, "A Yes with no amount stays a Yes")
        XCTAssertEqual(Q.state(of: "sauna", hasAmount: true, in: values), .unanswered)
        XCTAssertEqual(Q.state(of: "nap", hasAmount: false, in: values), .unanswered)
        let imported = Q.DayValues(answers: ["gym": false])
        XCTAssertEqual(Q.state(of: "gym", hasAmount: true, in: imported), .no, "A No from elsewhere reads as 0")
    }

    // MARK: Mark the rest

    private let targets = [
        Q.Target(question: "bed", hasAmount: false),
        Q.Target(question: "late", hasAmount: false),
        Q.Target(question: "beer", hasAmount: true),
        Q.Target(question: "sauna", hasAmount: true),
    ]

    func testMarkTheRestWritesNoForBlankQuestionsAndZeroForBlankAmounts() {
        let values = Q.DayValues(answers: ["bed": true], numeric: [:])
        XCTAssertEqual(Q.markRest(targets, in: values), [
            .answer(question: "late", yes: false),
            .amount(question: "beer", value: 0),
            .amount(question: "sauna", value: 0),
        ])
    }

    func testMarkTheRestNeverTouchesAnAnsweredQuestionAndIsEmptyOnceEverythingIsAnswered() {
        let values = Q.DayValues(answers: ["bed": true, "late": false, "beer": true, "sauna": false],
                                 numeric: ["beer": 2, "sauna": 0])
        XCTAssertTrue(Q.markRest(targets, in: values).isEmpty)
        XCTAssertEqual(Q.answeredCount(targets, in: values), 4)
    }

    func testAnImportedAnswerCountsAsAnsweredSoMarkTheRestSkipsIt() {
        let merged = Q.merged(native: .init(), imported: .init(answers: ["late": true]))
        XCTAssertEqual(Q.markRest(targets, in: merged).map(\.question), ["bed", "beer", "sauna"])
    }

    func testSameAsYesterdayFillsOnlyBlanksTheEarlierDayAnswered() {
        let current = Q.DayValues(answers: ["bed": false])
        let earlier = Q.DayValues(answers: ["bed": true, "late": true, "beer": true, "sauna": false],
                                  numeric: ["beer": 3])
        XCTAssertEqual(Q.copyFromEarlier(targets, current: current, earlier: earlier), [
            .answer(question: "late", yes: true),
            .amount(question: "beer", value: 3),
            .answer(question: "sauna", yes: false),
        ])
        XCTAssertTrue(Q.copyFromEarlier(targets, current: current, earlier: .init()).isEmpty)
    }

    // MARK: Imported answers

    func testAnImportedAnswerCountsAndShowsItsValue() {
        let imported = Q.DayValues(answers: ["caffeine": true])
        let merged = Q.merged(native: .init(), imported: imported)
        XCTAssertEqual(Q.state(of: "caffeine", hasAmount: false, in: merged), .yes)
        XCTAssertEqual(Q.answeredCount([.init(question: "caffeine", hasAmount: false)], in: merged), 1)
    }

    func testANativeTapOverridesAnImportedAnswerQuestionByQuestion() {
        let imported = Q.DayValues(answers: ["caffeine": true, "alcohol": true, "stress": true],
                                   numeric: ["alcohol": 3])
        let native = Q.DayValues(answers: ["caffeine": false, "alcohol": false], numeric: ["alcohol": 0])
        let merged = Q.merged(native: native, imported: imported)
        XCTAssertEqual(merged.answers["caffeine"], false)
        XCTAssertEqual(merged.answers["alcohol"], false)
        XCTAssertEqual(merged.numeric["alcohol"], 0, "The tapped zero replaces the imported amount")
        XCTAssertEqual(merged.answers["stress"], true, "Questions never tapped keep the imported answer")
    }

    func testClearingATapBringsTheImportedAnswerBack() {
        let imported = Q.DayValues(answers: ["caffeine": true])
        var native = Q.DayValues(answers: ["caffeine": false])
        XCTAssertEqual(Q.state(of: "caffeine", hasAmount: false, in: Q.merged(native: native, imported: imported)), .no)
        native.answers["caffeine"] = nil
        XCTAssertEqual(Q.state(of: "caffeine", hasAmount: false, in: Q.merged(native: native, imported: imported)), .yes)
    }

    func testValuesReadOnlyTheRequestedDay() {
        let entries = [
            JournalEntry(day: "2026-10-22", question: "Caffeine", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-10-22", question: "Alcohol", answeredYes: true, notes: nil, numericValue: 2),
            JournalEntry(day: "2026-10-21", question: "Stress", answeredYes: true, notes: nil),
        ]
        let values = Q.values(from: entries, day: "2026-10-22")
        XCTAssertEqual(values, Q.DayValues(answers: ["Caffeine": true, "Alcohol": true], numeric: ["Alcohol": 2]))
    }

    func testLoggedDaysFollowTheScreenNotTheLastRead() {
        let base: Set<String> = ["2026-10-20", "2026-10-21"]
        XCTAssertEqual(Q.loggedDays(base, day: "2026-10-22", values: .init(answers: ["a": true])),
                       base.union(["2026-10-22"]))
        XCTAssertEqual(Q.loggedDays(base, day: "2026-10-21", values: .init()), ["2026-10-20"])
        XCTAssertEqual(Q.loggedDays(base, day: "2026-10-22", values: nil), base)
    }

    // MARK: Grid order

    func testTheGridKeepsTheGroupOrderThenEachGroupsSortOrder() {
        func item(_ q: String, _ group: JournalGroup, _ sort: Int) -> JournalCatalogItem {
            JournalCatalogItem(canonical: q, displayName: nil, kind: .bool, group: group,
                               sortIndex: sort, hidden: false, custom: false)
        }
        let items = [
            item("Did you take magnesium?", .supplements, 0),
            item("Did you feel stressed?", .health, 1),
            item("Did you drink any alcohol?", .nutrition, 5),
            item("Did you read before bed?", .lifestyle, 9),
            item("Did you have caffeine late in the day?", .nutrition, 2),
        ]
        let tiles = JournalQuickLogTile.tiles(from: items, active: [])
        XCTAssertEqual(tiles.map(\.id), [
            "Did you read before bed?",                 // sleep setup
            "Did you have caffeine late in the day?",   // fuel, sort 2
            "Did you drink any alcohol?",               // fuel, sort 5
            "Did you feel stressed?",                   // recovery
            "Did you take magnesium?",                  // supplements
        ])
    }

    func testOnlyTheActiveQuestionsGetATileUnlessNoSetCouldBeRead() {
        func item(_ q: String) -> JournalCatalogItem {
            JournalCatalogItem(canonical: q, displayName: nil, kind: .bool, group: .other,
                               sortIndex: 0, hidden: false, custom: false)
        }
        let items = [item("A"), item("B"), item("C")]
        XCTAssertEqual(JournalQuickLogTile.tiles(from: items, active: ["A", "C"]).map(\.id), ["A", "C"])
        XCTAssertEqual(JournalQuickLogTile.tiles(from: items, active: []).count, 3)
    }

    // MARK: Stack line

    func testTheStackLineNamesItsItemsInPlainWords() {
        XCTAssertEqual(Q.stackSubtitle(names: ["Magnesium", "Sauna"]), "Log magnesium and sauna together")
        XCTAssertEqual(Q.stackSubtitle(names: ["Magnesium"]), "Log magnesium")
        XCTAssertNil(Q.stackSubtitle(names: []))
    }

    func testStreakTextNeedsMoreThanOneDay() {
        XCTAssertNil(Q.streakText(0))
        XCTAssertNil(Q.streakText(1))
        XCTAssertEqual(Q.streakText(9), "9 days in a row")
    }
}

/// The model that drives the grid: taps show at once, write through the host, and a stale read never undoes one.
@MainActor
final class JournalQuickLogModelTests: XCTestCase {
    private func tiles() -> [JournalQuickLogTile] {
        func item(_ q: String) -> JournalCatalogItem {
            JournalCatalogItem(canonical: q, displayName: nil, kind: .bool, group: .other,
                               sortIndex: 0, hidden: false, custom: false)
        }
        return JournalQuickLogTile.tiles(from: [item("Did you read before bed?"),
                                                item("Did you drink any alcohol?")], active: [])
    }

    /// The plain Yes/No question among the tiles (the other one counts drinks).
    private func plain(_ tiles: [JournalQuickLogTile]) -> JournalQuickLogTile {
        tiles.first { $0.amount == nil }!
    }

    private final class Recorder {
        var saved: [(String, JournalQuickLog.Write)] = []
        var cleared: [(String, String)] = []
        var didWrite = 0
    }

    private func model(recorder: Recorder, canWrite: Bool = true) -> JournalQuickLogModel {
        let model = JournalQuickLogModel()
        model.writer = .init(save: { day, write in recorder.saved.append((day, write)) },
                             clear: { day, question in recorder.cleared.append((day, question)) },
                             canWrite: { canWrite }, didWrite: { recorder.didWrite += 1 })
        return model
    }

    func testNothingCanBeTappedUntilADayIsSeeded() {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        model.tap(tiles()[0])
        XCTAssertTrue(recorder.saved.isEmpty)
    }

    func testATapShowsAtOnceAndWritesForTheDayItWasMadeOn() async {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        let tiles = tiles()
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        model.tap(plain(tiles))
        XCTAssertEqual(model.state(of: plain(tiles)), .yes)
        XCTAssertEqual(model.answeredCount, 1)
        model.tap(plain(tiles))
        XCTAssertEqual(model.state(of: plain(tiles)), .no)
        model.tap(plain(tiles))
        XCTAssertEqual(model.state(of: plain(tiles)), .yes)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.saved.map(\.0), ["2026-10-22", "2026-10-22", "2026-10-22"])
        XCTAssertEqual(recorder.saved.map(\.1.question), Array(repeating: "Did you read before bed?", count: 3))
        XCTAssertEqual(recorder.didWrite, 3)
    }

    func testCountedTilesAddAStepPerTapAndStepDownToZero() async {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        let tiles = tiles()
        let alcohol = tiles.first { $0.amount != nil }!
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        model.tap(alcohol)
        model.tap(alcohol)
        XCTAssertEqual(model.state(of: alcohol), .amount(2))
        model.stepDown(alcohol)
        XCTAssertEqual(model.state(of: alcohol), .amount(1))
        model.stepDown(alcohol)
        XCTAssertEqual(model.state(of: alcohol), .no, "Stepping down at 1 is an explicit No")
        model.stepDown(alcohol)
        XCTAssertEqual(model.state(of: alcohol), .no, "Nothing below zero")
    }

    func testAnImportedAnswerCountsAndATapReplacesIt() {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        let tiles = tiles()
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(),
                   imported: .init(answers: ["Did you read before bed?": true]), earlier: .init(), epoch: 0)
        XCTAssertEqual(model.answeredCount, 1, "The import counts as answered")
        XCTAssertEqual(model.state(of: plain(tiles)), .yes)
        XCTAssertFalse(model.hasNativeAnswer(plain(tiles)), "There is nothing of its own to clear")
        model.tap(plain(tiles))
        XCTAssertEqual(model.state(of: plain(tiles)), .no, "A tap on an imported Yes switches it to No")
        model.clear(plain(tiles))
        XCTAssertEqual(model.state(of: plain(tiles)), .yes, "Clearing the tap brings the import back")
    }

    func testMarkTheRestAnswersEveryBlankQuestionAndCompletesTheDay() async {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        let tiles = tiles()
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        model.tap(plain(tiles))
        XCTAssertFalse(model.isComplete)
        XCTAssertEqual(model.markRestWrites.count, 1)
        model.markRest()
        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(model.completionTick, 1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.saved.count, 2)
    }

    func testABlockedWriterStopsTheTapBeforeAnythingShows() {
        let recorder = Recorder()
        let model = model(recorder: recorder, canWrite: false)
        let tiles = tiles()
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        model.tap(plain(tiles))
        XCTAssertEqual(model.state(of: plain(tiles)), .unanswered)
        XCTAssertTrue(recorder.saved.isEmpty)
    }

    func testAReadThatStartedBeforeATapCannotUndoIt() {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        let tiles = tiles()
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        let staleEpoch = model.changeEpoch
        model.tap(plain(tiles))
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: staleEpoch)
        XCTAssertEqual(model.state(of: plain(tiles)), .yes, "The older, blank read is dropped")
    }

    func testSwitchingDayBlanksThePageUntilTheNewDayArrives() {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        let tiles = tiles()
        model.seed(day: "2026-10-22", tiles: tiles, native: .init(answers: ["Did you read before bed?": true]),
                   imported: .init(), earlier: .init(), epoch: 0)
        model.reset()
        XCTAssertNil(model.dayKey)
        XCTAssertEqual(model.answeredCount, 0)
        model.tap(plain(tiles))
        XCTAssertTrue(recorder.saved.isEmpty, "Nothing is stored while the day is loading")
        model.seed(day: "2026-10-21", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        XCTAssertEqual(model.dayKey, "2026-10-21")
        XCTAssertEqual(model.answeredCount, 0)
    }
}
