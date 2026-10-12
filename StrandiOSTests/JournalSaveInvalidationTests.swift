import XCTest
import WhoopStore
@testable import NOOP

/// ORG-10 (data half): a journal save didn't move `refreshSeq`, so Insights restored its same-seq cache and
/// the classic journal reopened with the old answers.
@MainActor
final class JournalSaveInvalidationTests: XCTestCase {
    private func cachedRepository() async throws -> Repository {
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(try await WhoopStore.inMemory())
        repository.insightsCache = InsightsLoadCache(
            behaviours: [:], controls: [:], importedQuestions: [], dayAnswers: ["Caffeine": false],
            journalDayOffset: 0, outcomeByKey: [:], seriesByKey: [:], activityCosts: [],
            numericJournalByKey: [:])
        return repository
    }

    func testSavingAnAnswerDropsTheInsightsCacheAndBumpsTheDataVersion() async throws {
        let repository = try await cachedRepository()
        let version = repository.dataVersion
        await repository.saveJournalAnswer(day: "2026-10-12", question: "Caffeine", answeredYes: true)
        XCTAssertNil(repository.insightsCache)
        XCTAssertEqual(repository.dataVersion, version + 1)
    }

    func testSavingANumericAnswerDropsTheInsightsCache() async throws {
        let repository = try await cachedRepository()
        let version = repository.dataVersion
        await repository.saveJournalNumeric(day: "2026-10-12", question: "Caffeine mg", value: 200)
        XCTAssertNil(repository.insightsCache)
        XCTAssertEqual(repository.dataVersion, version + 1)
    }

    func testClearingAnAnswerDropsTheInsightsCache() async throws {
        let repository = try await cachedRepository()
        await repository.clearJournalAnswer(day: "2026-10-12", question: "Caffeine")
        XCTAssertNil(repository.insightsCache)
    }
}
