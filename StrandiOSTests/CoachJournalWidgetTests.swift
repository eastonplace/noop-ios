import XCTest
#if !COACH_JOURNAL_STANDALONE_TESTS
@testable import NOOP
#endif

final class CoachJournalWidgetTests: XCTestCase {
    func testExplicitNoIsAChangeFromNotLogged() {
        XCTAssertEqual(CoachJournalDraftPolicy.changes(saved: [:], draft: ["late-meal": false]),
                       ["late-meal": false])
    }

    func testUnchangedAnswersDoNotNeedReview() {
        XCTAssertTrue(CoachJournalDraftPolicy.changes(saved: ["walk": true, "late-meal": false],
                                                     draft: ["walk": true, "late-meal": false]).isEmpty)
    }

    func testOmittingASavedAnswerDoesNotClearIt() {
        XCTAssertTrue(CoachJournalDraftPolicy.changes(saved: ["walk": true], draft: [:]).isEmpty)
        XCTAssertEqual(CoachJournalDraftPolicy.answer(for: "walk", saved: ["walk": true], draft: [:]), true)
    }

    func testDraftAnswerWinsWithoutChangingSavedAnswers() {
        let saved = ["walk": true]
        let draft = ["walk": false]
        XCTAssertEqual(CoachJournalDraftPolicy.answer(for: "walk", saved: saved, draft: draft), false)
        XCTAssertEqual(CoachJournalDraftPolicy.changes(saved: saved, draft: draft), ["walk": false])
        XCTAssertEqual(saved, ["walk": true])
    }

    func testRepeatedSelectionStaysSelected() {
        var draft = ["walk": true]
        CoachJournalDraftPolicy.select(true, for: "walk", in: &draft)
        XCTAssertEqual(draft, ["walk": true])
        CoachJournalDraftPolicy.select(false, for: "walk", in: &draft)
        CoachJournalDraftPolicy.select(false, for: "walk", in: &draft)
        XCTAssertEqual(draft, ["walk": false])
    }

    func testNotLoggedStaysUnknown() {
        XCTAssertNil(CoachJournalDraftPolicy.answer(for: "walk", saved: [:], draft: [:]))
    }

    func testDiscardFollowsLaterSavedSnapshotWithoutProposingAnUndo() {
        var saved = ["walk": true]
        var draft: [String: Bool] = [:]
        CoachJournalDraftPolicy.select(false, for: "walk", in: &draft)
        CoachJournalDraftPolicy.discard(&draft)

        saved["walk"] = false // The full Journal saves a different answer while this widget is retained.

        XCTAssertTrue(draft.isEmpty, "Discard must remove intent, not copy the previous saved snapshot")
        XCTAssertEqual(CoachJournalDraftPolicy.answer(for: "walk", saved: saved, draft: draft), false)
        XCTAssertTrue(CoachJournalDraftPolicy.changes(saved: saved, draft: draft).isEmpty)
    }
}

#if COACH_JOURNAL_STANDALONE_TESTS
@main
enum CoachJournalWidgetTestMain {
    static func main() {
        XCTMain([testCase([
            ("testExplicitNoIsAChangeFromNotLogged", CoachJournalWidgetTests.testExplicitNoIsAChangeFromNotLogged),
            ("testUnchangedAnswersDoNotNeedReview", CoachJournalWidgetTests.testUnchangedAnswersDoNotNeedReview),
            ("testOmittingASavedAnswerDoesNotClearIt", CoachJournalWidgetTests.testOmittingASavedAnswerDoesNotClearIt),
            ("testDraftAnswerWinsWithoutChangingSavedAnswers", CoachJournalWidgetTests.testDraftAnswerWinsWithoutChangingSavedAnswers),
            ("testRepeatedSelectionStaysSelected", CoachJournalWidgetTests.testRepeatedSelectionStaysSelected),
            ("testNotLoggedStaysUnknown", CoachJournalWidgetTests.testNotLoggedStaysUnknown),
            ("testDiscardFollowsLaterSavedSnapshotWithoutProposingAnUndo", CoachJournalWidgetTests.testDiscardFollowsLaterSavedSnapshotWithoutProposingAnUndo)
        ])])
    }
}
#endif
