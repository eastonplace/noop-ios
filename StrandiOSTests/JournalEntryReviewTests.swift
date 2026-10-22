import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class JournalEntryReviewTests: XCTestCase {
    private let day = "2026-10-22"
    private let field = JournalEntryParser.Field(canonical: "Creatine", display: "Creatine", kind: .boolean)

    private func repository() async throws -> Repository {
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(try await WhoopStore.inMemory())
        _ = try await repository.journalEntryContext()
        return repository
    }

    private func review(in repository: Repository) async throws -> JournalEntryReview {
        let parsed = JournalEntryParser.parse("Creatine: yes", fields: [field])
        return try await repository.reviewJournalEntry(
            day: day, sourceContext: repository.journalEntrySourceContext,
            fields: [field], suggestions: parsed.suggestions)
    }

    func testReviewDoesNotWriteAndExplicitSaveUsesTheExistingNativeJournal() async throws {
        let repository = try await repository()
        let draft = try await review(in: repository)
        let before = await repository.nativeJournalAnswers(day: day)
        XCTAssertTrue(before.isEmpty)
        let version = repository.dataVersion

        try await repository.saveJournalEntry(
            review: draft, values: draft.suggestions, currentDay: day, currentFields: [field])

        let after = await repository.nativeJournalAnswers(day: day)
        XCTAssertEqual(after, [field.canonical: true])
        XCTAssertEqual(repository.dataVersion, version + 1)
    }

    func testChangedDayCannotSaveReviewToAnotherDay() async throws {
        let repository = try await repository()
        let draft = try await review(in: repository)

        do {
            try await repository.saveJournalEntry(
                review: draft, values: draft.suggestions, currentDay: "2026-10-23", currentFields: [field])
            XCTFail("A review must stay with its selected wake day")
        } catch let error as JournalEntryReviewError {
            XCTAssertEqual(error, .contextChanged)
        }
        let after = await repository.nativeJournalAnswers(day: day)
        XCTAssertTrue(after.isEmpty)
    }

    func testChangedCatalogCannotSaveAnOldTypeOrUnit() async throws {
        let repository = try await repository()
        let draft = try await review(in: repository)
        let changed = JournalEntryParser.Field(canonical: field.canonical, display: field.display, kind: .quantity(unit: "g"))

        do {
            try await repository.saveJournalEntry(
                review: draft, values: draft.suggestions, currentDay: day, currentFields: [changed])
            XCTFail("A changed catalog needs another review")
        } catch let error as JournalEntryReviewError {
            XCTAssertEqual(error, .contextChanged)
        }
    }

    func testSourceFenceRejectsReviewAndDoesNotInvalidateTheCacheAsASuccess() async throws {
        let repository = try await repository()
        let draft = try await review(in: repository)
        let version = repository.dataVersion
        repository.verifiedExternalSurfaceFenced = true

        do {
            try await repository.saveJournalEntry(
                review: draft, values: draft.suggestions, currentDay: day, currentFields: [field])
            XCTFail("Source replacement must reject an old review")
        } catch let error as JournalEntryReviewError {
            XCTAssertEqual(error, .contextChanged)
        }
        XCTAssertEqual(repository.dataVersion, version)
    }

    func testConcurrentNativeEditRequiresAnotherReview() async throws {
        let repository = try await repository()
        let draft = try await review(in: repository)
        await repository.saveJournalAnswer(day: day, question: field.canonical, answeredYes: false)

        do {
            try await repository.saveJournalEntry(
                review: draft, values: draft.suggestions, currentDay: day, currentFields: [field])
            XCTFail("A new explicit answer must not be silently replaced")
        } catch let error as ReviewedJournalSaveError {
            XCTAssertEqual(error, .changedSinceReview)
        }
        let after = await repository.nativeJournalAnswers(day: day)
        XCTAssertEqual(after[field.canonical], false)
    }
}
