import XCTest
@testable import WhoopStore

final class JournalReviewedSaveTests: XCTestCase {
    private let day = "2026-10-22"
    private let native = "noop-journal"

    func testReviewedBatchWritesOnlyNativeKeysAndPreservesExistingNotes() async throws {
        let store = try await WhoopStore.inMemory()
        let old = JournalEntry(day: day, question: "Caffeine", answeredYes: true, notes: "Original note", numericValue: 100)
        try await store.upsertJournal([old], deviceId: native)
        try await store.upsertJournal([old], deviceId: "my-whoop")

        let edits = [
            ReviewedJournalChange(day: day, question: "Caffeine", answeredYes: true, numericValue: 200, expected: old),
            ReviewedJournalChange(day: day, question: "Creatine", answeredYes: false, numericValue: nil, expected: nil),
        ]
        let count = try await store.saveReviewedJournal(edits, expectedDatabaseInstanceId: store.databaseInstanceId())
        let rows = try await store.journalEntries(deviceId: native, from: day, to: day)
        let imported = try await store.journalEntries(deviceId: "my-whoop", from: day, to: day)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(rows.first { $0.question == "Caffeine" }?.numericValue, 200)
        XCTAssertEqual(rows.first { $0.question == "Caffeine" }?.notes, "Original note")
        XCTAssertEqual(rows.first { $0.question == "Creatine" }?.answeredYes, false)
        XCTAssertEqual(imported, [old])
    }

    func testConcurrentAnswerChangeRejectsEntireBatchWithoutPartialWrites() async throws {
        let store = try await WhoopStore.inMemory()
        let reviewed = JournalEntry(day: day, question: "Caffeine", answeredYes: true, notes: nil, numericValue: 100)
        let editedElsewhere = JournalEntry(day: day, question: "Caffeine", answeredYes: true, notes: "New note", numericValue: 250)
        try await store.upsertJournal([editedElsewhere], deviceId: native)
        let edits = [
            ReviewedJournalChange(day: day, question: "Creatine", answeredYes: true, numericValue: nil, expected: nil),
            ReviewedJournalChange(day: day, question: "Caffeine", answeredYes: true, numericValue: 200, expected: reviewed),
        ]

        do {
            _ = try await store.saveReviewedJournal(edits, expectedDatabaseInstanceId: store.databaseInstanceId())
            XCTFail("A value changed after review must require another review")
        } catch let error as ReviewedJournalSaveError {
            XCTAssertEqual(error, .changedSinceReview)
        }
        let rows = try await store.journalEntries(deviceId: native, from: day, to: day)
        XCTAssertEqual(rows, [editedElsewhere])
    }

    func testNewAnswerSinceReviewConflictsWithPreviouslyUnansweredField() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = JournalEntry(day: day, question: "Creatine", answeredYes: false, notes: nil)
        try await store.upsertJournal([existing], deviceId: native)

        do {
            _ = try await store.saveReviewedJournal([
                ReviewedJournalChange(day: day, question: "Creatine", answeredYes: true, numericValue: nil, expected: nil)
            ], expectedDatabaseInstanceId: store.databaseInstanceId())
            XCTFail("A new explicit No must not be overwritten without review")
        } catch let error as ReviewedJournalSaveError {
            XCTAssertEqual(error, .changedSinceReview)
        }
    }

    func testInvalidBatchIsRejectedBeforeAnyWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let invalidBatches = [
            [ReviewedJournalChange(day: "2026-02-30", question: "Creatine", answeredYes: true, numericValue: nil, expected: nil)],
            [ReviewedJournalChange(day: day, question: "Caffeine", answeredYes: true, numericValue: .infinity, expected: nil)],
            [ReviewedJournalChange(day: day, question: "Caffeine", answeredYes: false, numericValue: 200, expected: nil)],
            [ReviewedJournalChange(day: day, question: "", answeredYes: true, numericValue: nil, expected: nil)],
            [ReviewedJournalChange(day: day, question: "Caffeine", answeredYes: true, numericValue: -1, expected: nil)],
        ]
        for batch in invalidBatches {
            do {
                _ = try await store.saveReviewedJournal(batch, expectedDatabaseInstanceId: store.databaseInstanceId())
                XCTFail("Invalid review data should fail")
            } catch let error as ReviewedJournalSaveError {
                XCTAssertEqual(error, .invalidChange)
            }
        }
        let rows = try await store.journalEntries(deviceId: native, from: "2000-01-01", to: "2100-12-31")
        XCTAssertTrue(rows.isEmpty)
    }

    func testDuplicateOrMixedDayChangesAreRejected() async throws {
        let store = try await WhoopStore.inMemory()
        let first = ReviewedJournalChange(day: day, question: "Creatine", answeredYes: true, numericValue: nil, expected: nil)
        let nextDay = ReviewedJournalChange(day: "2026-10-23", question: "Caffeine", answeredYes: true, numericValue: 200, expected: nil)
        for batch in [[first, first], [first, nextDay]] {
            do {
                _ = try await store.saveReviewedJournal(batch, expectedDatabaseInstanceId: store.databaseInstanceId())
                XCTFail("A review owns one day and one value per question")
            } catch let error as ReviewedJournalSaveError {
                XCTAssertEqual(error, .invalidChange)
            }
        }
    }

    func testReviewFromAnotherDatabaseCannotWriteAnyAnswers() async throws {
        let original = try await WhoopStore.inMemory()
        let replacement = try await WhoopStore.inMemory()
        let identity = try await original.databaseInstanceId()
        let edit = ReviewedJournalChange(day: day, question: "Creatine", answeredYes: true, numericValue: nil, expected: nil)

        do {
            _ = try await replacement.saveReviewedJournal([edit], expectedDatabaseInstanceId: identity)
            XCTFail("A review from the previous database cannot write into its replacement")
        } catch let error as ReviewedJournalSaveError {
            XCTAssertEqual(error, .databaseChanged)
        }
        let rows = try await replacement.journalEntries(deviceId: native, from: day, to: day)
        XCTAssertTrue(rows.isEmpty)
    }
}
