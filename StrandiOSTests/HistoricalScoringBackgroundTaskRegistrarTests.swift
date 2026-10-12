import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
private final class BackgroundScoringPendingWindowStore: HealthKitPendingWindowPersisting {
    var value: HealthKitSyncWindow?

    init(value: HealthKitSyncWindow? = nil) {
        self.value = value
    }

    func load() -> HealthKitSyncWindow? { value }

    func save(_ window: HealthKitSyncWindow?) throws {
        value = window
    }
}

@MainActor
final class HistoricalScoringBackgroundTaskRegistrarTests: XCTestCase {
    func testIdentifierIsBundleDerivedAndPermittedByTheBuiltApp() throws {
        let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let expected = bundleIdentifier + ".rescore"

        XCTAssertEqual(HistoricalScoringBackgroundTaskRegistrar.identifier, expected)

        let permitted = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )
        XCTAssertTrue(permitted.contains(expected))
    }

    func testCompletionPolicyRetriesUnknownDeferredOrPendingDurableWork() {
        let completed = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 1,
            deferredWork: 0,
            pendingWork: 0,
            alreadyRunning: false
        )
        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(for: completed),
            .complete
        )

        let pending = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 0,
            deferredWork: 0,
            pendingWork: 1,
            alreadyRunning: false
        )
        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(for: pending),
            .retry
        )

        let deferred = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 0,
            deferredWork: 1,
            pendingWork: 0,
            alreadyRunning: false
        )
        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(for: deferred),
            .retry
        )

        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(for: nil),
            .retry
        )

        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(
                for: completed,
                healthScoringPending: true
            ),
            .retry,
            "The shared rescore request must remain armed while the HealthKit journal is pending"
        )

        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(
                for: completed,
                healthImportPending: true,
                healthScoringPending: false
            ),
            .retry,
            "A locked HealthKit import must keep the shared recovery wake armed"
        )
    }

    func testBackgroundDrainClearsRestoredHealthKitJournalBeforeHistoricalPipeline() async {
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )
        let persistence = BackgroundScoringPendingWindowStore(value: window)
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: persistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier
        )
        let completed = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 1,
            deferredWork: 0,
            pendingWork: 0,
            alreadyRunning: false
        )
        var order: [String] = []

        let result = await HistoricalScoringBackgroundTaskRegistrar.runBackgroundWork(
            drainHealthImport: {
                order.append("health-import")
                return true
            },
            drainHealthScoring: {
                await scoring.runAndWait(
                    analyze: { candidate in
                        XCTAssertEqual(candidate, window)
                        order.append("health-analysis")
                        return true
                    },
                    publish: { candidate in
                        XCTAssertEqual(candidate, window)
                        order.append("health-publication")
                        return true
                    }
                )
                return scoring.pending == nil
            },
            runHistorical: {
                order.append("historical")
                return completed
            }
        )

        XCTAssertEqual(result, completed)
        XCTAssertEqual(order, ["health-import", "health-analysis", "health-publication", "historical"])
        XCTAssertNil(persistence.value)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    func testLockedHealthImportStillDrainsRecoveryBeforeHistoricalWork() async {
        let completed = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 1,
            deferredWork: 0,
            pendingWork: 0,
            alreadyRunning: false
        )
        var order: [String] = []

        let result = await HistoricalScoringBackgroundTaskRegistrar.runBackgroundWork(
            drainHealthImport: {
                order.append("health-import-locked")
                return false
            },
            drainHealthScoring: {
                order.append("health-scoring")
                return true
            },
            runHistorical: {
                order.append("historical")
                return completed
            }
        )

        XCTAssertEqual(result, completed)
        XCTAssertEqual(order, ["health-import-locked", "health-scoring", "historical"])
    }

    /// Review finding (parked HealthKit journal starves BG): a parked or backing-off scoring journal returns
    /// false at once, and the registrar returned before the strap pipeline on every BG wake.
    func testAParkedHealthScoringJournalStillRunsTheStrapPipelineAndRetries() async {
        let completed = HistoricalPipelineRuntimeResult(
            admittedReceipts: 1,
            completedWork: 1,
            deferredWork: 0,
            pendingWork: 0,
            alreadyRunning: false
        )
        var order: [String] = []

        let result = await HistoricalScoringBackgroundTaskRegistrar.runBackgroundWork(
            drainHealthImport: {
                order.append("health-import")
                return true
            },
            drainHealthScoring: {
                order.append("health-scoring-parked")
                return false
            },
            runHistorical: {
                order.append("historical")
                return completed
            }
        )

        XCTAssertEqual(result, completed)
        XCTAssertEqual(order, ["health-import", "health-scoring-parked", "historical"])
        XCTAssertEqual(
            HistoricalScoringBackgroundTaskRegistrar.completionDisposition(
                for: result, healthImportPending: false, healthScoringPending: true),
            .retry,
            "the parked journal still keeps the request armed")
    }

    func testCancelledBackgroundDrainKeepsHealthKitJournalReleasesFenceAndSkipsHistorical() async {
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 300),
            end: Date(timeIntervalSince1970: 400)
        )
        let persistence = BackgroundScoringPendingWindowStore(value: window)
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: persistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier
        )
        var analysisStarted = false
        var historicalRan = false

        let worker = Task { @MainActor in
            await HistoricalScoringBackgroundTaskRegistrar.runBackgroundWork(
                drainHealthImport: { true },
                drainHealthScoring: {
                    await scoring.runAndWait(
                        analyze: { _ in
                            analysisStarted = true
                            do {
                                try await Task.sleep(nanoseconds: 60_000_000_000)
                                return true
                            } catch {
                                return false
                            }
                        },
                        publish: { _ in
                            XCTFail("A cancelled analysis must not publish")
                            return true
                        }
                    )
                    return scoring.pending == nil
                },
                runHistorical: {
                    historicalRan = true
                    return HistoricalPipelineRuntimeResult(
                        admittedReceipts: 0,
                        completedWork: 1,
                        deferredWork: 0,
                        pendingWork: 0,
                        alreadyRunning: false
                    )
                }
            )
        }

        while !analysisStarted { await Task.yield() }
        worker.cancel()
        let result = await worker.value

        XCTAssertNil(result)
        XCTAssertFalse(historicalRan)
        XCTAssertEqual(persistence.value, window)
        XCTAssertFalse(barrier.blocksRefreshes, "a cancelled run releases the fence (CC-1)")
    }

    func testCancelledBackgroundDrainCannotPublishWhenAnalysisFinishesAfterCancellation() async {
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 500),
            end: Date(timeIntervalSince1970: 600)
        )
        let persistence = BackgroundScoringPendingWindowStore(value: window)
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: persistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier
        )
        var analysisContinuation: CheckedContinuation<Void, Never>?
        var publicationRan = false
        var historicalRan = false

        let worker = Task { @MainActor in
            await HistoricalScoringBackgroundTaskRegistrar.runBackgroundWork(
                drainHealthImport: { true },
                drainHealthScoring: {
                    await scoring.runAndWait(
                        analyze: { _ in
                            await withCheckedContinuation { continuation in
                                analysisContinuation = continuation
                            }
                            return true
                        },
                        publish: { _ in
                            publicationRan = true
                            return true
                        }
                    )
                    return scoring.pending == nil
                },
                runHistorical: {
                    historicalRan = true
                    return nil
                }
            )
        }

        while analysisContinuation == nil { await Task.yield() }
        worker.cancel()
        analysisContinuation?.resume()
        let result = await worker.value

        XCTAssertNil(result)
        XCTAssertFalse(publicationRan)
        XCTAssertFalse(historicalRan)
        XCTAssertEqual(persistence.value, window)
        XCTAssertFalse(barrier.blocksRefreshes, "a cancelled run releases the fence (CC-1)")
    }
}
#endif
