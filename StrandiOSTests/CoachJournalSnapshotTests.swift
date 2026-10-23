import XCTest
import Combine
import WhoopStore
@testable import NOOP

@MainActor
final class CoachJournalSnapshotTests: XCTestCase {
    private func repository() async throws -> Repository {
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(try await WhoopStore.inMemory())
        _ = try await repo.journalEntryContext()
        return repo
    }

    func testSnapshotKeepsUnknownSeparateFromExplicitNoAndKeepsNumericZero() async throws {
        let repo = try await repository()
        await repo.saveJournalAnswer(day: "2026-10-22", question: "Alcohol", answeredYes: false)
        await repo.saveJournalNumeric(day: "2026-10-22", question: "Caffeine", value: 0)
        let snapshot = try await repo.coachJournalSnapshot(day: "2026-10-22")
        XCTAssertEqual(snapshot.answers["Alcohol"], false)
        XCTAssertNil(snapshot.answers["Magnesium"])
        XCTAssertEqual(snapshot.numericAnswers["Caffeine"], 0)
        XCTAssertEqual(snapshot.day, "2026-10-22")
        XCTAssertEqual(snapshot.sourceContext, repo.journalEntrySourceContext)
    }

    func testANumericZeroIsAnExplicitNoAndAPositiveAmountIsYes() async throws {
        let repo = try await repository()
        await repo.saveJournalNumeric(day: "2026-10-22", question: "Alcohol", value: 0)
        await repo.saveJournalNumeric(day: "2026-10-22", question: "Caffeine", value: 2)
        let answers = await repo.nativeJournalAnswers(day: "2026-10-22")
        XCTAssertEqual(answers["Alcohol"], false, "Zero servings must not count as drinking")
        XCTAssertEqual(answers["Caffeine"], true)
        let numeric = await repo.nativeJournalNumeric(day: "2026-10-22")
        XCTAssertEqual(numeric["Alcohol"], 0, "The logged zero keeps its amount")
        XCTAssertEqual(numeric["Caffeine"], 2)
    }

    func testSnapshotDoesNotBorrowAnotherDaysAnswers() async throws {
        let repo = try await repository()
        await repo.saveJournalAnswer(day: "2026-10-21", question: "Alcohol", answeredYes: true)
        let snapshot = try await repo.coachJournalSnapshot(day: "2026-10-22")
        XCTAssertTrue(snapshot.answers.isEmpty)
        XCTAssertEqual(snapshot.details.note, "")
        XCTAssertNil(snapshot.details.mood)
    }

    func testFencedSourceCannotLoadSnapshot() async throws {
        let repo = try await repository()
        repo.verifiedExternalSurfaceFenced = true
        do {
            _ = try await repo.coachJournalSnapshot(day: "2026-10-22")
            XCTFail("Fenced sources must not reveal an old journal")
        } catch { }
    }

    func testMalformedDayCannotLoadSnapshot() async throws {
        let repo = try await repository()
        do {
            _ = try await repo.coachJournalSnapshot(day: "2026-02-30")
            XCTFail("Invalid dates must not silently use today")
        } catch { }
    }

    func testSuccessfulMoodSavePublishesJournalRevisionButInvalidMoodDoesNot() async throws {
        let repo = try await repository()
        let original = repo.journalRevision
        await repo.saveMood(day: "2026-10-22", value: 0)
        XCTAssertEqual(repo.journalRevision, original)
        await repo.saveMood(day: "2026-10-22", value: 4)
        XCTAssertEqual(repo.journalRevision, original + 1)
        let snapshot = try await repo.coachJournalSnapshot(day: "2026-10-22")
        XCTAssertEqual(snapshot.details.mood, 4)
    }

    func testNilRepositoryPreviewSessionDoesNotReadOrOfferManualWrites() async {
        let session = CoachJournalSession(repository: nil, day: "2026-10-22")
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: true)
        session.refresh()
        await Task.yield()
        XCTAssertNil(session.repository)
        XCTAssertNil(session.catalog)
        XCTAssertNil(session.snapshot)
        XCTAssertFalse(session.isLoading)
        XCTAssertFalse(session.access.canUseManualJournal)
    }

    func testInjectedRepositoryPreviewDoesNotOpenOrMigrateTheCatalog() async throws {
        let repo = try await repository()
        let session = CoachJournalSession(repository: repo, day: "2026-10-22")
        XCTAssertNil(session.catalog)
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: true)
        session.refresh()
        await Task.yield()
        XCTAssertNil(session.catalog)
        XCTAssertNil(session.manualCatalog())
        XCTAssertNil(session.snapshot)
        XCTAssertFalse(session.isLoading)
    }

    func testCatalogReloadSeesAnEditFromAnotherInstanceWithoutRepersisting() throws {
        let suite = "CoachJournalSnapshotTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = JournalCatalogStore(defaults: defaults)
        let second = JournalCatalogStore(defaults: defaults)
        first.rename("Did you drink any alcohol?", to: "Alcohol last night")
        let persisted = try XCTUnwrap(defaults.data(forKey: "journal.catalog.v2"))
        var changeNotifications = 0
        let observation = NotificationCenter.default.publisher(for: .init("noop.notificationJournalDidChange"))
            .sink { _ in changeNotifications += 1 }
        defer { observation.cancel() }
        XCTAssertTrue(second.reloadFromDefaults())
        XCTAssertEqual(defaults.data(forKey: "journal.catalog.v2"), persisted)
        XCTAssertEqual(second.item(for: "Did you drink any alcohol?")?.display, "Alcohol last night")
        XCTAssertFalse(second.reloadFromDefaults())
        XCTAssertEqual(defaults.data(forKey: "journal.catalog.v2"), persisted)
        XCTAssertEqual(changeNotifications, 0, "Reload must not persist or announce a catalog write")
    }

    func testCatalogResetClearsInMemoryDeltasWithoutRecreatingTheRemovedKey() {
        let suite = "CoachJournalSnapshotTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = JournalCatalogStore(defaults: defaults)
        catalog.rename("Did you drink any alcohol?", to: "Alcohol last night")
        defaults.removeObject(forKey: "journal.catalog.v2")
        XCTAssertTrue(catalog.reloadFromDefaults())
        XCTAssertTrue(catalog.items.isEmpty)
        XCTAssertNil(defaults.data(forKey: "journal.catalog.v2"))
        XCTAssertFalse(catalog.reloadFromDefaults())
    }

    func testPauseAndResumePreservesAnExplicitQuickDraft() async throws {
        let repo = try await repository()
        let session = CoachJournalSession(repository: repo, day: "2026-10-22")
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: false)
        session.draftAnswers = ["Did you drink any alcohol?": false]
        session.pause()
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: false)
        XCTAssertEqual(session.draftAnswers["Did you drink any alcohol?"], false)
        session.pause()
    }

    func testRevokingConsentClearsLoadedValuesAndQuickDraftSynchronously() async throws {
        let repo = try await repository()
        let session = CoachJournalSession(repository: repo, day: "2026-10-22")
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: false)
        session.draftAnswers = ["Did you drink any alcohol?": false]
        session.configure(coachEnabled: true, usesPersonalData: false, isPreview: false)
        XCTAssertTrue(session.draftAnswers.isEmpty)
        XCTAssertNil(session.snapshot)
        XCTAssertFalse(session.canRead)
        XCTAssertFalse(session.isLoading)
    }

    func testInactiveSessionDoesNotOpenCatalogOrRestartSnapshotReads() async throws {
        let repo = try await repository()
        let session = CoachJournalSession(repository: repo, day: "2026-10-22")
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: false, active: false)
        session.refresh()
        XCTAssertNil(session.catalog)
        XCTAssertFalse(session.isLoading)
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: false, active: true)
        XCTAssertTrue(session.isLoading)
        session.draftAnswers = ["Did you drink any alcohol?": false]
        session.configure(coachEnabled: true, usesPersonalData: true, isPreview: false, active: false)
        session.refresh()
        await Task.yield()
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.snapshot)
        XCTAssertEqual(session.draftAnswers["Did you drink any alcohol?"], false)
    }
}
