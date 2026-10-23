import XCTest
import GRDB
@testable import WhoopStore

final class JournalDayDetailsTests: XCTestCase {
    private let day = "2026-10-22"

    private func details(_ store: WhoopStore, day: String? = nil, note: String, mood: Int?) async throws -> ReviewedJournalDayDetailsChange {
        let target = day ?? self.day
        return ReviewedJournalDayDetailsChange(day: target, note: note, mood: mood,
                                               expected: try await store.journalDayDetails(day: target))
    }

    private func save(_ store: WhoopStore, _ details: ReviewedJournalDayDetailsChange,
                      answers: [ReviewedJournalChange] = []) async throws {
        try await store.saveReviewedJournal(answers, expectedDatabaseInstanceId: store.databaseInstanceId(), dayDetails: details)
    }

    func testDetailsOnlySaveUsesSeparateNativeNoteAndExistingMoodNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = JournalEntry(day: day, question: "Caffeine", answeredYes: true, notes: "Imported note", numericValue: 125)
        try await store.upsertJournal([imported], deviceId: "my-whoop")
        let edit = try await details(store, note: "  A quiet morning.\nI slept well.  ", mood: 4)
        try await save(store, edit)

        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.note, edit.note, "Free text is not silently trimmed or turned into an answer")
        XCTAssertEqual(saved.mood, 4)
        let mood = try await store.metricSeries(deviceId: "noop-mood", key: "mood", from: day, to: day)
        XCTAssertEqual(mood, [MetricPoint(day: day, key: "mood", value: 4)])
        let answers = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(answers.isEmpty, "A day note must not become a synthetic behavior")
        let importedAfter = try await store.journalEntries(deviceId: "my-whoop", from: day, to: day)
        XCTAssertEqual(importedAfter, [imported])
    }

    func testEmptyNoteAndNilMoodExplicitlyClearOnlyTheReviewedDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await save(store, details(store, note: "Today", mood: 2))
        try await save(store, details(store, day: "2026-10-21", note: "Yesterday", mood: 5))
        let answer = JournalEntry(day: day, question: "Caffeine", answeredYes: true, notes: "Keep dose note", numericValue: 200)
        try await store.upsertJournal([answer], deviceId: "noop-journal")
        try await save(store, details(store, note: "", mood: nil))

        let cleared = try await store.journalDayDetails(day: day)
        XCTAssertNil(cleared.note)
        XCTAssertNil(cleared.mood)
        let yesterday = try await store.journalDayDetails(day: "2026-10-21")
        XCTAssertEqual(yesterday.note, "Yesterday")
        XCTAssertEqual(yesterday.mood, 5)
        let answers = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(answers, [answer])
    }

    func testStaleNoteRejectsAnswersAndMoodAsOneBatch() async throws {
        let store = try await WhoopStore.inMemory()
        let stale = try await details(store, note: "Obsolete edit", mood: 4)
        try await save(store, details(store, note: "Newer note", mood: 2))
        let answer = ReviewedJournalChange(day: day, question: "Creatine", answeredYes: true, numericValue: nil, expected: nil)
        do {
            try await save(store, stale, answers: [answer])
            XCTFail("A changed day note must reject the complete reviewed save")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .changedSinceReview) }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.note, "Newer note")
        XCTAssertEqual(saved.mood, 2)
        let answers = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(answers.isEmpty)
    }

    func testStaleRawMoodCannotHideBehindRoundedDisplayValue() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "mood", value: 4)], deviceId: "noop-mood")
        let stale = try await details(store, note: "New note", mood: 5)
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "mood", value: 4.25)], deviceId: "noop-mood")
        do {
            try await save(store, stale)
            XCTFail("Compare the exact stored mood, not a rounded UI value")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .changedSinceReview) }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.mood, 4.25)
        XCTAssertNil(saved.note)
    }

    func testCanonicallyEquivalentButDifferentRawNoteRequiresAnotherReview() async throws {
        let store = try await WhoopStore.inMemory()
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift text equality normalizes equivalent Unicode")
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        try await save(store, details(store, note: composed, mood: 4))
        let stale = try await details(store, note: "Must not overwrite", mood: 5)
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE journalDayNote SET note = ? WHERE deviceId = 'noop-journal' AND day = ?",
                           arguments: [decomposed, self.day])
        }
        do {
            try await save(store, stale)
            XCTFail("Raw-byte changes count as a conflicting note edit")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .changedSinceReview) }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.note.map { Array($0.utf8) }, Array(decomposed.utf8))
        XCTAssertEqual(saved.mood, 4)
    }

    func testChangedAnswerNoteRejectsDayDetailsToo() async throws {
        let store = try await WhoopStore.inMemory()
        let before = JournalEntry(day: day, question: "Magnesium", answeredYes: true, notes: "Before")
        try await store.upsertJournal([before], deviceId: "noop-journal")
        let change = try await details(store, note: "New day note", mood: 4)
        let after = JournalEntry(day: day, question: "Magnesium", answeredYes: true, notes: "Edited elsewhere")
        try await store.upsertJournal([after], deviceId: "noop-journal")
        do {
            try await save(store, change, answers: [.init(day: day, question: before.question, answeredYes: false, numericValue: nil, expected: before)])
            XCTFail("A per-answer note is part of the reviewed native row")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .changedSinceReview) }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertNil(saved.note)
        XCTAssertNil(saved.mood)
    }

    func testNumericZeroAndPerAnswerNotesSurviveCombinedSave() async throws {
        let store = try await WhoopStore.inMemory()
        let before = JournalEntry(day: day, question: "Caffeine", answeredYes: true, notes: "Dose context", numericValue: 200)
        try await store.upsertJournal([before], deviceId: "noop-journal")
        try await save(store, details(store, note: "Different day note", mood: 3), answers: [
            .init(day: day, question: before.question, answeredYes: true, numericValue: 0, expected: before),
            .init(day: day, question: "Stress", answeredYes: false, numericValue: nil, expected: nil),
        ])
        let answers = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        let quantity = try XCTUnwrap(answers.first { $0.question == before.question })
        XCTAssertTrue(quantity.answeredYes)
        XCTAssertEqual(quantity.numericValue, 0)
        XCTAssertEqual(quantity.notes, "Dose context")
        XCTAssertEqual(answers.first { $0.question == "Stress" }?.answeredYes, false)
    }

    func testAnswerOnlySaveLeavesUnreviewedDayDetailsUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        try await save(store, details(store, note: "Keep note", mood: 2))
        try await store.saveReviewedJournal([
            .init(day: day, question: "Magnesium", answeredYes: true, numericValue: nil, expected: nil),
        ], expectedDatabaseInstanceId: store.databaseInstanceId())
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.note, "Keep note")
        XCTAssertEqual(saved.mood, 2)
    }

    func testInvalidDetailsRejectBeforeAnyAnswerWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let expected = try await store.journalDayDetails(day: day)
        let invalid = [
            ReviewedJournalDayDetailsChange(day: day, note: String(repeating: "a", count: 8_001), mood: nil, expected: expected),
            .init(day: day, note: "Embedded\0NUL", mood: nil, expected: expected),
            .init(day: day, note: "Note", mood: 0, expected: expected),
            .init(day: day, note: "Note", mood: 6, expected: expected),
            .init(day: "2026-02-30", note: "Note", mood: 3, expected: expected),
            .init(day: "2026-10-23", note: "Note", mood: 3, expected: expected),
        ]
        for change in invalid {
            do {
                try await save(store, change, answers: [.init(day: day, question: "Magnesium", answeredYes: true, numericValue: nil, expected: nil)])
                XCTFail("Reject invalid details before persisting any field")
            } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .invalidChange) }
        }
        let answers = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(answers.isEmpty)
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved, expected)
    }

    func testNoteLimitCountsUTF8BytesRatherThanCharacters() async throws {
        let store = try await WhoopStore.inMemory()
        let largest = String(repeating: "🙂", count: 2_000)
        try await save(store, details(store, note: largest, mood: 1))
        do {
            try await save(store, details(store, note: largest + "🙂", mood: 5))
            XCTFail("Eight thousand UTF8 bytes is the note limit")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .invalidChange) }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.note, largest)
        XCTAssertEqual(saved.mood, 1)
    }

    func testDatabaseReplacementRejectsDetailsOnlySave() async throws {
        let original = try await WhoopStore.inMemory()
        let replacement = try await WhoopStore.inMemory()
        let change = try await details(original, note: "Original database", mood: 5)
        do {
            try await replacement.saveReviewedJournal([], expectedDatabaseInstanceId: original.databaseInstanceId(), dayDetails: change)
            XCTFail("A day-details review belongs to one database instance")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .databaseChanged) }
        let saved = try await replacement.journalDayDetails(day: day)
        XCTAssertNil(saved.note)
        XCTAssertNil(saved.mood)
    }

    func testLateSQLiteFailureRollsBackAnswersNoteAndMood() async throws {
        let store = try await WhoopStore.inMemory()
        let change = try await details(store, note: "Must roll back", mood: 4)
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_test_mood BEFORE INSERT ON metricSeries
                WHEN NEW.deviceId = 'noop-mood' AND NEW.key = 'mood'
                BEGIN SELECT RAISE(ABORT, 'Injected persistence failure'); END;
                """)
        }
        do {
            try await save(store, change, answers: [.init(day: day, question: "Magnesium", answeredYes: true, numericValue: nil, expected: nil)])
            XCTFail("The SQLite failure must escape the save boundary")
        } catch is DatabaseError { }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertNil(saved.note)
        XCTAssertNil(saved.mood)
        let answers = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(answers.isEmpty)
    }

    func testInvalidDayReadIsRejected() async throws {
        let store = try await WhoopStore.inMemory()
        for invalid in ["2026-02-30", "today", "2026-1-1", "2026-10-22\0"] {
            do {
                _ = try await store.journalDayDetails(day: invalid)
                XCTFail("A details read must use an exact civil-day key")
            } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .invalidChange) }
        }
    }
}
