import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
final class HistoricalScoringRequestOwnershipTests: XCTestCase {
    private let drained = HistoricalPipelineRuntimeResult(
        admittedReceipts: 0, completedWork: 1, deferredWork: 0, pendingWork: 0, alreadyRunning: false)

    private func journal() throws -> HealthKitPendingWindowDefaultsStore {
        let suite = "HistoricalScoringRequestOwnershipTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return HealthKitPendingWindowDefaultsStore(defaults: defaults, key: "pending")
    }

    private var window: HealthKitSyncWindow {
        HealthKitSyncWindow(start: Date(timeIntervalSince1970: 1_781_557_000),
                            end: Date(timeIntervalSince1970: 1_781_560_000))
    }

    func testDrainedStrapPipelinePreservesRetryForLockedHealthImportAndItsScoringJournal() async throws {
        let importJournal = try journal()
        let scoringJournal = try journal()
        let scoring = HealthKitScoringCoordinator(
            persistence: scoringJournal, notificationCenter: NotificationCenter(),
            publicationBarrier: RepositoryPublicationBarrier())
        var retryRequests = 0
        let importer = HealthKitSyncCoordinator(
            persistence: importJournal, scoringCoordinator: scoring,
            scheduleRetry: { retryRequests += 1 }, operation: { _ in false })
        try importer.offer(window)
        await importer.runAndWait()
        XCTAssertEqual(retryRequests, 1, "a locked import already armed the shared recovery request")
        XCTAssertEqual(importJournal.load(), window)
        XCTAssertEqual(scoringJournal.load(), window)
        var cancellations = 0

        HistoricalScoringBackgroundTaskRegistrar.refreshRequestAfterHistoricalPipeline(
            for: drained, effortRescorePending: false,
            healthImportPending: { importer.pending != nil },
            healthScoringPending: { scoring.pending != nil },
            scheduleRequest: { retryRequests += 1 }, cancelRequest: { cancellations += 1 })

        XCTAssertEqual(cancellations, 0, "a successful strap drain does not own the pending HealthKit retry")
        XCTAssertEqual(retryRequests, 2)
        XCTAssertEqual(importJournal.load(), window)
        XCTAssertEqual(scoringJournal.load(), window)
    }

    func testRestoredScoringJournalAloneKeepsTheSharedRequestArmed() throws {
        let importJournal = try journal()
        let scoringJournal = try journal()
        try scoringJournal.save(window)
        let restoredScoring = HealthKitScoringCoordinator(
            persistence: scoringJournal, notificationCenter: NotificationCenter(),
            publicationBarrier: RepositoryPublicationBarrier())
        var scheduled = 0
        var cancelled = 0

        HistoricalScoringBackgroundTaskRegistrar.refreshRequestAfterHistoricalPipeline(
            for: drained, effortRescorePending: false,
            healthImportPending: { importJournal.load() != nil },
            healthScoringPending: { restoredScoring.pending != nil },
            scheduleRequest: { scheduled += 1 }, cancelRequest: { cancelled += 1 })

        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(scoringJournal.load(), window)
    }

    func testOnlyImportJournalPendingStillKeepsTheSharedRequestArmed() throws {
        let importJournal = try journal()
        try importJournal.save(window)
        var scheduled = 0
        var cancelled = 0

        HistoricalScoringBackgroundTaskRegistrar.refreshRequestAfterHistoricalPipeline(
            for: drained, effortRescorePending: false,
            healthImportPending: { importJournal.load() != nil }, healthScoringPending: { false },
            scheduleRequest: { scheduled += 1 }, cancelRequest: { cancelled += 1 })

        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(cancelled, 0)
    }

    func testAllThreePipelinesDrainedCancelsTheSharedRequest() {
        var scheduled = 0
        var cancelled = 0
        HistoricalScoringBackgroundTaskRegistrar.refreshRequestAfterHistoricalPipeline(
            for: drained, effortRescorePending: false,
            healthImportPending: { false }, healthScoringPending: { false },
            scheduleRequest: { scheduled += 1 }, cancelRequest: { cancelled += 1 })

        XCTAssertEqual(scheduled, 0)
        XCTAssertEqual(cancelled, 1)
    }

    func testEffortRescoreDebtStillKeepsTheSharedRequestArmed() {
        var scheduled = 0
        var cancelled = 0
        HistoricalScoringBackgroundTaskRegistrar.refreshRequestAfterHistoricalPipeline(
            for: drained, effortRescorePending: true,
            healthImportPending: { false }, healthScoringPending: { false },
            scheduleRequest: { scheduled += 1 }, cancelRequest: { cancelled += 1 })

        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(cancelled, 0)
    }
}
#endif
