import XCTest
import StrandAnalytics
@testable import NOOP

final class CoachJournalComposerTests: XCTestCase {
    private let caffeine = JournalEntryParser.Field(
        canonical: "Caffeine", display: "Caffeine", kind: .quantity(unit: "mg"))

    func testPresentationPreservesExactSeedAndKeepsExistingCallersCompatible() {
        let empty = JournalEntryPresentation(day: "2026-10-22", sourceIdentity: "source")
        XCTAssertEqual(empty.initialText, "")
        XCTAssertTrue(empty.initialSuggestions.isEmpty)

        let suggestion = JournalEntryParser.Suggestion(
            canonical: "Caffeine", value: .quantity(0.0000001), excerpt: "An exact quick action")
        let seeded = JournalEntryPresentation(
            day: "2026-10-21", sourceIdentity: "source", initialText: "My entry",
            initialSuggestions: [suggestion])
        XCTAssertEqual(seeded.day, "2026-10-21")
        XCTAssertEqual(seeded.initialText, "My entry")
        XCTAssertEqual(seeded.initialSuggestions, [suggestion])
        XCTAssertNotEqual(empty.id, seeded.id)
    }

    func testExactQuickActionSeedDoesNotRoundTripThroughNarrativeParser() {
        let suggestion = JournalEntryParser.Suggestion(
            canonical: caffeine.canonical, value: .quantity(0.0000001), excerpt: "Quick action")
        let draft = JournalEntryComposerDraft(text: "A quick check-in", suggestions: [suggestion])
        let parsed = JournalEntryParser.parse(draft.text, fields: [caffeine])

        XCTAssertTrue(parsed.suggestions.isEmpty)
        XCTAssertEqual(draft.reviewSuggestions(from: parsed), [suggestion])
    }

    func testEditingThenRevertingTextDoesNotResurrectQuickActionSeed() {
        let suggestion = JournalEntryParser.Suggestion(
            canonical: caffeine.canonical, value: .quantity(200), excerpt: "Quick action")
        var draft = JournalEntryComposerDraft(text: "A quick check-in", suggestions: [suggestion])
        draft.text = "Caffeine: 50 mg"
        XCTAssertEqual(draft.reviewSuggestions(from: JournalEntryParser.parse(draft.text, fields: [caffeine])).first?.value,
                       .quantity(50))

        draft.text = "A quick check-in"
        XCTAssertTrue(draft.reviewSuggestions(from: JournalEntryParser.parse(draft.text, fields: [caffeine])).isEmpty)
    }

    func testIdenticalTextAssignmentKeepsExactSeed() {
        let suggestion = JournalEntryParser.Suggestion(
            canonical: caffeine.canonical, value: .quantity(200), excerpt: "Quick action")
        var draft = JournalEntryComposerDraft(text: "A quick check-in", suggestions: [suggestion])
        let sameText = draft.text
        draft.text = sameText

        XCTAssertEqual(draft.reviewSuggestions(from: JournalEntryParser.parse(draft.text, fields: [caffeine])), [suggestion])
    }

    func testCatalogInvalidationDiscardsExactSeed() {
        let suggestion = JournalEntryParser.Suggestion(
            canonical: caffeine.canonical, value: .quantity(200), excerpt: "Quick action")
        var draft = JournalEntryComposerDraft(text: "A quick check-in", suggestions: [suggestion])
        draft.invalidateSeedSuggestions()

        XCTAssertTrue(draft.reviewSuggestions(from: JournalEntryParser.parse(draft.text, fields: [caffeine])).isEmpty)
    }

    func testBlankNarrativeCanBeReviewedForNoteAndMoodOnly() {
        XCTAssertTrue(JournalEntryComposerDraft().canReviewText)
        XCTAssertTrue(JournalEntryComposerDraft(text: " \n ").canReviewText)
        XCTAssertFalse(JournalEntryComposerDraft(text: String(repeating: "🙂", count: 1_001)).canReviewText)
    }

    func testExistingDayDetailsArePreservedAndExcludedUntilOptedIn() {
        let draft = JournalEntryDayDetailsDraft(note: "  Existing note\n", mood: 4)

        XCTAssertFalse(draft.included)
        XCTAssertEqual(draft.note, "  Existing note\n")
        XCTAssertEqual(draft.mood, 4)
    }

    func testNoAnswersRequireExplicitDayDetailsOptIn() {
        XCTAssertNil(JournalEntryComposerDraft.valuesForSave([], includesDayDetails: false))
        XCTAssertEqual(JournalEntryComposerDraft.valuesForSave([], includesDayDetails: true), [])
    }

    func testInvalidIncludedQuantityCannotBeBypassedWithDayDetailsOptIn() {
        var edit = JournalEntryEditableValue(
            field: caffeine,
            suggestion: .init(canonical: caffeine.canonical, value: .quantity(200), excerpt: "Caffeine: 200 mg"))
        edit.quantity = "200 cups"

        XCTAssertNil(JournalEntryComposerDraft.valuesForSave([edit], includesDayDetails: true))
    }

    func testExcludedInvalidQuantityDoesNotBlockDayDetailsOnlySave() {
        var edit = JournalEntryEditableValue(
            field: caffeine,
            suggestion: .init(canonical: caffeine.canonical, value: .quantity(200), excerpt: "Caffeine: 200 mg"))
        edit.quantity = "200 cups"
        edit.included = false

        XCTAssertEqual(JournalEntryComposerDraft.valuesForSave([edit], includesDayDetails: true), [])
    }

    func testAppendingNarrativePreservesExistingNoteAndDoesNotOptInImplicitly() {
        var draft = JournalEntryDayDetailsDraft(note: "  Existing note\n", mood: 3)

        XCTAssertTrue(draft.appendEntryText("My exact entry.\n", maximumNoteBytes: 8_000))
        XCTAssertEqual(draft.note, "  Existing note\n\n\nMy exact entry.\n")
        XCTAssertEqual(draft.mood, 3)
        XCTAssertFalse(draft.included)
    }

    func testAppendingToAnEmptyNoteDoesNotAddASeparator() {
        var draft = JournalEntryDayDetailsDraft()

        XCTAssertTrue(draft.appendEntryText("My entry", maximumNoteBytes: 8_000))
        XCTAssertEqual(draft.note, "My entry")
    }

    func testBlankNarrativeAppendLeavesExistingNoteUnchanged() {
        var draft = JournalEntryDayDetailsDraft(note: "Keep this", mood: 2)

        XCTAssertFalse(draft.appendEntryText(" \n ", maximumNoteBytes: 8_000))
        XCTAssertEqual(draft.note, "Keep this")
        XCTAssertEqual(draft.mood, 2)
    }

    func testAppendCountsUTF8AndSeparatorWithoutTruncatingOrMutatingOnOverflow() {
        let original = String(repeating: "x", count: 7_996)
        var draft = JournalEntryDayDetailsDraft(note: original, mood: 5)

        XCTAssertFalse(draft.appendEntryText("🙂", maximumNoteBytes: 8_000))
        XCTAssertEqual(draft.note, original)
        XCTAssertEqual(draft.mood, 5)
    }

    func testAppendAcceptsExactlyTheUTF8Limit() {
        var draft = JournalEntryDayDetailsDraft(note: String(repeating: "x", count: 7_994))

        XCTAssertTrue(draft.appendEntryText("🙂", maximumNoteBytes: 8_000))
        XCTAssertEqual(draft.note.utf8.count, 8_000)
        XCTAssertTrue(draft.note.hasSuffix("\n\n🙂"))
    }

    func testNulContainingAppendIsRejectedWithoutChangingTheNote() {
        var draft = JournalEntryDayDetailsDraft(note: "Keep this", mood: 3)

        XCTAssertFalse(draft.appendEntryText("Hidden\0suffix", maximumNoteBytes: 8_000))
        XCTAssertEqual(draft.note, "Keep this")
        XCTAssertEqual(draft.mood, 3)
    }

    func testIncludedNoteRejectsNulCharacters() {
        var draft = JournalEntryDayDetailsDraft(note: "Hidden\0suffix")
        draft.included = true

        XCTAssertFalse(draft.isValid(maximumNoteBytes: 8_000))
    }

    func testIncludedDayDetailsValidateMoodAndNoteBytes() {
        var draft = JournalEntryDayDetailsDraft(note: "", mood: nil)
        draft.included = true
        XCTAssertTrue(draft.isValid(maximumNoteBytes: 8_000), "Explicit empty note and nil mood clear existing details")
        for mood in 1...5 {
            draft.mood = mood
            XCTAssertTrue(draft.isValid(maximumNoteBytes: 8_000))
        }
        for mood in [0, 6] {
            draft.mood = mood
            XCTAssertFalse(draft.isValid(maximumNoteBytes: 8_000))
        }
        draft.mood = nil
        draft.note = String(repeating: "🙂", count: 2_001)
        XCTAssertFalse(draft.isValid(maximumNoteBytes: 8_000))
        draft.included = false
        XCTAssertTrue(draft.isValid(maximumNoteBytes: 8_000), "Unchecked day details are not part of the save")
    }

    func testNarrativeEditInvalidatesReviewWithoutDiscardingAuthoredNoteOrMood() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.included = true
        details.note = "A note I have not saved"
        details.mood = 4

        // The composer's narrative-change handler invalidates only the reviewed authorization.
        details.invalidateReview()

        XCTAssertEqual(details.note, "A note I have not saved")
        XCTAssertEqual(details.mood, 4)
        XCTAssertTrue(details.hasVisibleDraft)
        XCTAssertNil(details.reviewedValues)
        XCTAssertFalse(details.included)
        XCTAssertFalse(details.canIncludeInSave)
    }

    func testConflictThenRereviewRefreshesSnapshotWithoutReplacingAuthoredValues() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.included = true
        details.note = "Keep this unsaved note"
        details.mood = 4

        // A failed save leaves the draft intact; Review again reads a fresh persisted snapshot.
        details.invalidateReview()
        XCTAssertTrue(details.receiveReview(note: "Changed on another screen", mood: 5))

        XCTAssertEqual(details.reviewedValues?.note, "Changed on another screen")
        XCTAssertEqual(details.reviewedValues?.mood, 5)
        XCTAssertEqual(details.note, "Keep this unsaved note")
        XCTAssertEqual(details.mood, 4)
        XCTAssertFalse(details.included)
        XCTAssertFalse(details.canIncludeInSave)
        details.included = true
        XCTAssertTrue(details.canIncludeInSave)
    }

    func testRereviewRefreshesUntouchedMoodWhileKeepingAuthoredNote() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.note = "My unsaved note"
        details.invalidateReview()

        XCTAssertTrue(details.receiveReview(note: "New saved note", mood: 5))

        XCTAssertEqual(details.note, "My unsaved note")
        XCTAssertEqual(details.mood, 5)
        XCTAssertEqual(details.reviewedValues?.note, "New saved note")
        XCTAssertFalse(details.included)
    }

    func testRereviewRefreshesUntouchedNoteWhileKeepingAuthoredMood() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.mood = 4
        details.invalidateReview()

        XCTAssertTrue(details.receiveReview(note: "New saved note", mood: 5))

        XCTAssertEqual(details.note, "New saved note")
        XCTAssertEqual(details.mood, 4)
        XCTAssertFalse(details.included)
    }

    func testExplicitClearsSurviveConflictAndRereview() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.included = true
        details.note = ""
        details.mood = nil
        details.invalidateReview()

        XCTAssertTrue(details.receiveReview(note: "Concurrent note", mood: 5))

        XCTAssertEqual(details.note, "")
        XCTAssertNil(details.mood)
        XCTAssertTrue(details.hasVisibleDraft)
        XCTAssertFalse(details.included)
        XCTAssertEqual(details.reviewedValues?.note, "Concurrent note")
        XCTAssertEqual(details.reviewedValues?.mood, 5)
    }

    func testContextInvalidationRetainsCopyableDraftAndRejectsAnotherContextReview() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.included = true
        details.note = "Keep this for the original wake day"
        details.mood = 4

        details.invalidateContext()

        XCTAssertEqual(details.note, "Keep this for the original wake day")
        XCTAssertEqual(details.mood, 4)
        XCTAssertTrue(details.hasVisibleDraft)
        XCTAssertNil(details.reviewedValues)
        XCTAssertFalse(details.included)
        XCTAssertFalse(details.canIncludeInSave)
        XCTAssertFalse(details.receiveReview(note: "Another source or day", mood: 1))
        XCTAssertEqual(details.note, "Keep this for the original wake day")
        XCTAssertEqual(details.mood, 4)
        details.included = true
        XCTAssertFalse(details.canIncludeInSave, "A UI selection cannot bypass the old context fence")
    }

    func testFailedReviewLeavesTheCopyableDraftWithoutSaveAuthorization() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        details.note = "My authored note"
        details.mood = 5
        details.included = true

        // The read fails after invalidation, so no replacement review is received.
        details.invalidateReview()

        XCTAssertEqual(details.note, "My authored note")
        XCTAssertEqual(details.mood, 5)
        XCTAssertTrue(details.hasVisibleDraft)
        XCTAssertFalse(details.canIncludeInSave)
        details.included = true
        XCTAssertFalse(details.canIncludeInSave)
    }

    func testIdenticalAssignmentsDoNotPreventUntouchedValuesFromRefreshing() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        let sameNote = details.note
        let sameMood = details.mood
        details.note = sameNote
        details.mood = sameMood

        XCTAssertTrue(details.receiveReview(note: "New saved note", mood: 5))

        XCTAssertEqual(details.note, "New saved note")
        XCTAssertEqual(details.mood, 5)
        XCTAssertFalse(details.included)
    }

    func testAppendedNarrativeSurvivesRereviewAsAuthoredNote() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertTrue(details.receiveReview(note: "Saved note", mood: 2))
        XCTAssertTrue(details.appendEntryText("My narrative", maximumNoteBytes: 8_000))
        details.invalidateReview()

        XCTAssertTrue(details.receiveReview(note: "Concurrent note", mood: 3))

        XCTAssertEqual(details.note, "Saved note\n\nMy narrative")
        XCTAssertEqual(details.mood, 3)
        XCTAssertFalse(details.included)
    }

    func testNewDraftCannotAuthorizeDayDetailsWithoutAReview() {
        var details = JournalEntryDayDetailsDraft()
        XCTAssertFalse(details.hasVisibleDraft)
        details.included = true

        XCTAssertFalse(details.canIncludeInSave)
        XCTAssertNil(details.reviewedValues)
    }
}
