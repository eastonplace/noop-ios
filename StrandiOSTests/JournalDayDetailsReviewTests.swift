import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class JournalDayDetailsReviewTests: XCTestCase {
    private let day = "2026-10-22"
    private let field = JournalEntryParser.Field(canonical: "Creatine", display: "Creatine", kind: .boolean)

    private func repository() async throws -> (Repository, WhoopStore) {
        let repository = Repository(deviceId: Repository.whoopSource)
        let store = try await WhoopStore.inMemory()
        repository.setStoreForTesting(store)
        _ = try await repository.journalEntryContext()
        return (repository, store)
    }

    private func review(_ repo: Repository, values: [JournalEntryParser.Suggestion] = [],
                        includeDayDetails: Bool = true) async throws -> JournalEntryReview {
        try await repo.reviewJournalEntry(day: day, sourceContext: repo.journalEntrySourceContext,
                                         fields: [field], suggestions: values, includeDayDetails: includeDayDetails)
    }

    func testDetailsReviewIsExplicitAndDoesNotWriteAnything() async throws {
        let (repo, store) = try await repository()
        let version = repo.dataVersion
        let reviewed = try await review(repo)
        XCTAssertEqual(reviewed.dayDetails, JournalEntryDayDetails(note: "", mood: nil))
        XCTAssertEqual(repo.dataVersion, version)
        let details = try await store.journalDayDetails(day: day)
        XCTAssertNil(details.note)
        XCTAssertNil(details.mood)
        let answers = await repo.nativeJournalAnswers(day: day)
        XCTAssertTrue(answers.isEmpty)
    }

    func testExplicitDetailsOnlySaveIsVisibleThroughJournalAndMoodAPIs() async throws {
        let (repo, _) = try await repository()
        let reviewed = try await review(repo)
        let version = repo.dataVersion
        let intended = JournalEntryDayDetails(note: "Felt rested after a quiet evening.", mood: 4)
        try await repo.saveJournalEntry(review: reviewed, values: [], currentDay: day,
                                        currentFields: [field], dayDetails: intended)
        let details = try await repo.journalDayDetails(day: day, sourceContext: repo.journalEntrySourceContext)
        XCTAssertEqual(details, intended)
        let mood = await repo.mood(day: day)
        XCTAssertEqual(mood, 4)
        XCTAssertEqual(repo.dataVersion, version + 1)
    }

    func testAnswerOnlyReviewCannotAuthorizeDayDetails() async throws {
        let (repo, _) = try await repository()
        let values = JournalEntryParser.parse("Creatine: yes", fields: [field]).suggestions
        let reviewed = try await review(repo, values: values, includeDayDetails: false)
        XCTAssertNil(reviewed.dayDetails)
        do {
            try await repo.saveJournalEntry(review: reviewed, values: values, currentDay: day,
                                            currentFields: [field], dayDetails: .init(note: "Not reviewed", mood: 5))
            XCTFail("Day details must have been part of the visible review")
        } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .invalidValues) }
        let answers = await repo.nativeJournalAnswers(day: day)
        XCTAssertTrue(answers.isEmpty)
    }

    func testEmptyAnswersWithoutExplicitDetailsEditAreRejected() async throws {
        let (repo, _) = try await repository()
        let reviewed = try await review(repo)
        do {
            try await repo.saveJournalEntry(review: reviewed, values: [], currentDay: day, currentFields: [field])
            XCTFail("A details snapshot does not itself authorize any write")
        } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .invalidValues) }
    }

    func testDayAndCatalogChangesRejectDetailsOnlySave() async throws {
        let (repo, _) = try await repository()
        let reviewed = try await review(repo)
        for (currentDay, fields) in [("2026-10-23", [field]), (day, [])] {
            do {
                try await repo.saveJournalEntry(review: reviewed, values: [], currentDay: currentDay,
                                                currentFields: fields, dayDetails: .init(note: "Old context", mood: 4))
                XCTFail("Date and catalog guards apply to details-only saves")
            } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .contextChanged) }
        }
    }

    func testSourceFenceRejectsDetailsSaveAndReadWithoutCacheInvalidation() async throws {
        let (repo, _) = try await repository()
        let reviewed = try await review(repo)
        let context = repo.journalEntrySourceContext
        let version = repo.dataVersion
        repo.verifiedExternalSurfaceFenced = true
        do {
            try await repo.saveJournalEntry(review: reviewed, values: [], currentDay: day,
                                            currentFields: [field], dayDetails: .init(note: "Old source", mood: 4))
            XCTFail("The source fence applies before write admission")
        } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .contextChanged) }
        do {
            _ = try await repo.journalDayDetails(day: day, sourceContext: context)
            XCTFail("A fenced read must not publish an old note")
        } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .contextChanged) }
        XCTAssertEqual(repo.dataVersion, version)
    }

    func testConcurrentMoodTapRequiresAnotherReview() async throws {
        let (repo, _) = try await repository()
        let reviewed = try await review(repo)
        await repo.saveMood(day: day, value: 2)
        let version = repo.dataVersion
        do {
            try await repo.saveJournalEntry(review: reviewed, values: [], currentDay: day,
                                            currentFields: [field], dayDetails: .init(note: "Stale", mood: 5))
            XCTFail("The existing mood control participates in the same conflict boundary")
        } catch let error as ReviewedJournalSaveError { XCTAssertEqual(error, .changedSinceReview) }
        XCTAssertEqual(repo.dataVersion, version)
        let mood = await repo.mood(day: day)
        XCTAssertEqual(mood, 2)
    }

    func testOmittedDayDetailsDoNotOverwriteConcurrentMoodChange() async throws {
        let (repo, _) = try await repository()
        let values = JournalEntryParser.parse("Creatine: yes", fields: [field]).suggestions
        let reviewed = try await review(repo, values: values)
        await repo.saveMood(day: day, value: 2)
        try await repo.saveJournalEntry(review: reviewed, values: values, currentDay: day, currentFields: [field])
        let mood = await repo.mood(day: day)
        XCTAssertEqual(mood, 2)
        let answers = await repo.nativeJournalAnswers(day: day)
        XCTAssertEqual(answers[field.canonical], true)
    }

    func testInvalidDayDetailsAreRejectedBeforeSavingAnswers() async throws {
        let (repo, _) = try await repository()
        let values = JournalEntryParser.parse("Creatine: yes", fields: [field]).suggestions
        let reviewed = try await review(repo, values: values)
        for invalid in [JournalEntryDayDetails(note: "Note", mood: 6),
                        .init(note: String(repeating: "n", count: 8_001), mood: nil),
                        .init(note: "Invalid\0note", mood: nil)] {
            do {
                try await repo.saveJournalEntry(review: reviewed, values: values, currentDay: day,
                                                currentFields: [field], dayDetails: invalid)
                XCTFail("Invalid details must not partially save reviewed answers")
            } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .invalidValues) }
        }
        let answers = await repo.nativeJournalAnswers(day: day)
        XCTAssertTrue(answers.isEmpty)
    }

    func testInvalidCivilDayCannotBeReviewedForAnswersOrDetails() async throws {
        let (repo, _) = try await repository()
        let values = JournalEntryParser.parse("Creatine: yes", fields: [field]).suggestions
        for includeDetails in [false, true] {
            do {
                _ = try await repo.reviewJournalEntry(day: "2026-02-30", sourceContext: repo.journalEntrySourceContext,
                                                       fields: [field], suggestions: values, includeDayDetails: includeDetails)
                XCTFail("Review must reject a nonexistent civil day before displaying a saveable form")
            } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .invalidValues) }
        }
    }

    func testInvalidExistingMoodIsNotSilentlyRoundedIntoAReviewedValue() async throws {
        let (repo, store) = try await repository()
        try await store.upsertMetricSeries([.init(day: day, key: "mood", value: 4.25)], deviceId: "noop-mood")
        do {
            _ = try await review(repo)
            XCTFail("A raw invalid mood must not be turned into an apparently valid reviewed choice")
        } catch let error as JournalEntryReviewError { XCTAssertEqual(error, .invalidValues) }
        let saved = try await store.journalDayDetails(day: day)
        XCTAssertEqual(saved.mood, 4.25)
        XCTAssertNil(saved.note)
    }
}
