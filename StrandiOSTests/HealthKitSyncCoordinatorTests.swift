import HealthKit
import UIKit
import XCTest
import WhoopStore
@testable import NOOP

#if os(iOS)
@MainActor
private final class PendingWindowMemoryStore: HealthKitPendingWindowPersisting {
    enum Failure: Error { case injected }

    var value: HealthKitSyncWindow?
    var failNextSave = false
    private(set) var saves: [HealthKitSyncWindow?] = []

    func load() -> HealthKitSyncWindow? { value }

    func save(_ window: HealthKitSyncWindow?) throws {
        if failNextSave {
            failNextSave = false
            throw Failure.injected
        }
        value = window
        saves.append(window)
    }
}

@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class CommittedWindowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HealthKitSyncWindow] = []

    func record(_ window: HealthKitSyncWindow) {
        lock.withLock { storage.append(window) }
    }

    var windows: [HealthKitSyncWindow] {
        lock.withLock { storage }
    }
}

@MainActor
private final class GeneratedHeartRatePageLoader: HealthKitAnchoredPageLoading {
    enum Failure: Error { case injected }

    let totalSamples: Int
    let failOnPage: Int?
    private(set) var requestedLimits: [Int] = []
    private(set) var maximumReturnedCount = 0
    private var emitted = 0

    init(totalSamples: Int, failOnPage: Int? = nil) {
        self.totalSamples = totalSamples
        self.failOnPage = failOnPage
    }

    func loadPage(
        type: HKSampleType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> HealthKitAnchorPage {
        requestedLimits.append(limit)
        if requestedLimits.count == failOnPage { throw Failure.injected }

        let count = min(limit, totalSamples - emitted)
        let heartRate = try XCTUnwrap(type as? HKQuantityType)
        let samples: [HKSample] = (0..<count).map { offset in
            let timestamp = TimeInterval(emitted + offset)
            return HKQuantitySample(
                type: heartRate,
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 60),
                start: Date(timeIntervalSince1970: timestamp),
                end: Date(timeIntervalSince1970: timestamp)
            )
        }
        emitted += count
        maximumReturnedCount = max(maximumReturnedCount, samples.count)
        return HealthKitAnchorPage(
            samples: samples,
            deletedCount: 0,
            newAnchor: HKQueryAnchor(fromValue: emitted)
        )
    }
}

final class HealthKitSyncCoordinatorTests: XCTestCase {
    func testExportDeletionCommitJournalsBoundedIdentityBatchesBeforeDelete() async throws {
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .heartRate))
        let unit = HKUnit.count().unitDivided(by: .minute())
        let samples: [HKSample] = (0..<805).map { index in
            let start = Date(timeIntervalSince1970: TimeInterval(index * 60))
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: 60),
                start: start,
                end: start.addingTimeInterval(60)
            )
        }
        var events: [String] = []
        var batchSizes: [Int] = []

        let deleted = try await HealthKitExportDeletionCommit.commit(
            sampleType: type,
            loadSamples: {
                events.append("load")
                return samples
            },
            recordIdentities: { identities in
                events.append("journal")
                batchSizes.append(identities.count)
            },
            delete: {
                events.append("delete")
                return samples.count
            }
        )

        XCTAssertEqual(deleted, 805)
        XCTAssertEqual(batchSizes, [400, 400, 5])
        XCTAssertEqual(events, ["load", "journal", "journal", "journal", "delete"])
    }

    func testExportDeletionCommitDoesNotDeleteWhenIdentityJournalFails() async throws {
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .respiratoryRate))
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(
                unit: HKUnit.count().unitDivided(by: .minute()),
                doubleValue: 14
            ),
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 100)
        )
        var deleted = false

        do {
            _ = try await HealthKitExportDeletionCommit.commit(
                sampleType: type,
                loadSamples: { [sample] },
                recordIdentities: { _ in throw PendingWindowMemoryStore.Failure.injected },
                delete: {
                    deleted = true
                    return 1
                }
            )
            XCTFail("Expected journal failure")
        } catch PendingWindowMemoryStore.Failure.injected { }

        XCTAssertFalse(deleted)
    }

    func testOwnExportDeletionPageAdvancesAnchorWithoutReopeningHistory() async throws {
        var events: [String] = []
        let window = try await HealthKitObserverPageCommit.commit(
            page: HealthKitAnchorPage(samples: [], deletedObjectUUIDs: ["own-hr"], newAnchor: HKQueryAnchor(fromValue: 1)),
            exportedObjectUUIDs: ["own-hr"], importedIdentities: [], initialScan: false, now: Date(),
            earliestLocalDate: { Date(timeIntervalSince1970: 1_436_587_200) },
            offer: { _ in events.append("import") }, saveAnchor: { _ in events.append("anchor") },
            retireExports: { ids in XCTAssertEqual(ids, ["own-hr"]); events.append("retire") })
        XCTAssertNil(window, "Replacing our own HR must not reopen the 2015 inbound window")
        XCTAssertEqual(events, ["anchor", "retire"])
    }

    func testMixedDeletionPagePreservesUnknownExternalHistoricalRepair() async throws {
        var events: [String] = []
        let earliest = Date(timeIntervalSince1970: 1_436_587_200)
        let window = try await HealthKitObserverPageCommit.commit(
            page: HealthKitAnchorPage(samples: [], deletedObjectUUIDs: ["own", "external"], newAnchor: HKQueryAnchor(fromValue: 2)),
            exportedObjectUUIDs: ["own"], importedIdentities: [], initialScan: false, now: Date(),
            earliestLocalDate: { earliest }, offer: { _ in events.append("import") },
            saveAnchor: { _ in events.append("anchor") }, retireExports: { _ in events.append("retire") })
        XCTAssertEqual(window?.start, Calendar.current.startOfDay(for: earliest))
        XCTAssertEqual(events, ["import", "anchor", "retire"])
    }

    func testOwnExportIdentityCannotWidenKnownExternalDeletionWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let externalStart = now.addingTimeInterval(-3_600)
        let imported = [
            HealthKitObjectIdentity(
                sampleType: HKQuantityTypeIdentifier.heartRate.rawValue,
                objectUUID: "own",
                startTs: 1_436_587_200,
                endTs: 1_436_587_260
            ),
            HealthKitObjectIdentity(
                sampleType: HKQuantityTypeIdentifier.heartRate.rawValue,
                objectUUID: "external",
                startTs: Int(externalStart.timeIntervalSince1970),
                endTs: Int(now.timeIntervalSince1970)
            ),
        ]

        let window = try await HealthKitObserverPageCommit.commit(
            page: HealthKitAnchorPage(
                samples: [],
                deletedObjectUUIDs: ["own", "external"],
                newAnchor: HKQueryAnchor(fromValue: 22)
            ),
            exportedObjectUUIDs: ["own"],
            importedIdentities: imported,
            initialScan: false,
            now: now,
            earliestLocalDate: {
                XCTFail("A known external deletion must not request a full-history fallback")
                return nil
            },
            offer: { _ in },
            saveAnchor: { _ in },
            retireExports: { _ in }
        )

        XCTAssertEqual(window?.start, Calendar.current.startOfDay(for: externalStart))
    }

    func testObserverJournalFailureDoesNotAdvanceAnchorOrRetireExports() async throws {
        var events: [String] = []
        do {
            _ = try await HealthKitObserverPageCommit.commit(
                page: HealthKitAnchorPage(samples: [], deletedObjectUUIDs: ["own", "external"], newAnchor: HKQueryAnchor(fromValue: 3)),
                exportedObjectUUIDs: ["own"], importedIdentities: [], initialScan: false, now: Date(),
                earliestLocalDate: { nil }, offer: { _ in throw PendingWindowMemoryStore.Failure.injected },
                saveAnchor: { _ in events.append("anchor") }, retireExports: { _ in events.append("retire") })
            XCTFail("Expected journal failure")
        } catch PendingWindowMemoryStore.Failure.injected { }
        XCTAssertTrue(events.isEmpty)
    }

    func testObserverAnchorFailureRetainsOwnDeletionIdentitiesForReplay() async throws {
        var retired = false
        do {
            _ = try await HealthKitObserverPageCommit.commit(
                page: HealthKitAnchorPage(samples: [], deletedObjectUUIDs: ["own"], newAnchor: HKQueryAnchor(fromValue: 4)),
                exportedObjectUUIDs: ["own"], importedIdentities: [], initialScan: false, now: Date(),
                earliestLocalDate: { nil }, offer: { _ in },
                saveAnchor: { _ in throw PendingWindowMemoryStore.Failure.injected },
                retireExports: { _ in retired = true })
            XCTFail("Expected anchor failure")
        } catch PendingWindowMemoryStore.Failure.injected { }
        XCTAssertFalse(retired)
    }
    @MainActor
    /// Tests drive retries by hand, so the default policy has no backoff; retry tests pass their own.
    private func makeScoring(
        persistence: PendingWindowMemoryStore,
        notificationCenter: NotificationCenter = NotificationCenter(),
        retryPolicy: HealthKitScoringRetryPolicy = HealthKitScoringRetryPolicy(maximumAttempts: 3, backoff: [.zero])
    ) -> (HealthKitScoringCoordinator, RepositoryPublicationBarrier) {
        let barrier = RepositoryPublicationBarrier()
        return (
            HealthKitScoringCoordinator(
                persistence: persistence,
                notificationCenter: notificationCenter,
                publicationBarrier: barrier,
                retryPolicy: retryPolicy),
            barrier)
    }

    @MainActor
    func testAnalysisFailureDoesNotPublishDerivedSurfaces() async {
        var analysisCalls = 0
        var publicationCalls = 0

        let completed = await HealthKitScoringCoordinator.runAnalysisThenPublish(
            analyze: {
                analysisCalls += 1
                return false
            },
            publish: {
                publicationCalls += 1
                return true
            })

        XCTAssertFalse(completed)
        XCTAssertEqual(analysisCalls, 1)
        XCTAssertEqual(publicationCalls, 0)
    }

    @MainActor
    func testSuccessfulAnalysisPublishesExactlyOnceAfterAnalysis() async {
        var events: [String] = []

        let completed = await HealthKitScoringCoordinator.runAnalysisThenPublish(
            analyze: {
                events.append("analysis")
                return true
            },
            publish: {
                events.append("publication")
                return true
            })

        XCTAssertTrue(completed)
        XCTAssertEqual(events, ["analysis", "publication"])
    }

    @MainActor
    func testPublicationFailureIsNotReportedAsCompletion() async {
        let completed = await HealthKitScoringCoordinator.runAnalysisThenPublish(
            analyze: { true },
            publish: { false })

        XCTAssertFalse(completed)
    }

    private func newYorkCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour)))
    }

    @MainActor
    func testObserverBWidensImportAndPublishesOneDurableScoringUnion() async throws {
        let importPersistence = PendingWindowMemoryStore()
        let scoringPersistence = PendingWindowMemoryStore()
        let gate = AsyncGate()
        let notificationCenter = NotificationCenter()
        let (scoring, barrier) = makeScoring(
            persistence: scoringPersistence,
            notificationCenter: notificationCenter)
        let recorder = CommittedWindowRecorder()
        let token = notificationCenter.addObserver(
            forName: HealthKitSyncPublication.name,
            object: scoring,
            queue: nil
        ) { notification in
            if let window = HealthKitSyncPublication.window(from: notification) {
                recorder.record(window)
            }
        }
        defer { notificationCenter.removeObserver(token) }

        var calls: [HealthKitSyncWindow] = []
        let coordinator = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { window in
            calls.append(window)
            if calls.count == 1 { await gate.wait() }
            return true
        }
        let a = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 300))
        let b = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 250))

        try coordinator.offer(a)
        let firstRun = Task { @MainActor in await coordinator.runAndWait() }
        while !gate.isWaiting { await Task.yield() }

        try coordinator.offer(b)
        XCTAssertEqual(importPersistence.value, a.union(b), "B must be durable before A resumes")
        gate.open()
        await firstRun.value

        XCTAssertEqual(calls, [a, b], "A committed history import must not restart when a new delta arrives")
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(importPersistence.value)
        XCTAssertEqual(scoring.pending, a.union(b))
        XCTAssertEqual(scoringPersistence.value, a.union(b))
        XCTAssertEqual(recorder.windows, [a, a.union(b)],
                       "each pre-import journal edge is durable; scoring consumes only the final union")
        XCTAssertFalse(barrier.blocksRefreshes, "the fence opens with the import run, not with the journal")

        var scored: [HealthKitSyncWindow] = []
        await scoring.runAndWait(operation: { window in
            scored.append(window)
            return true
        })
        XCTAssertEqual(scored, [a.union(b)])
        XCTAssertNil(scoring.pending)
        XCTAssertNil(scoringPersistence.value)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    @MainActor
    func testScoringNotificationIsScopedToOriginatingCoordinator() async throws {
        let notificationCenter = NotificationCenter()
        let observedPersistence = PendingWindowMemoryStore()
        let unrelatedPersistence = PendingWindowMemoryStore()
        let (observed, _) = makeScoring(
            persistence: observedPersistence,
            notificationCenter: notificationCenter)
        let (unrelated, _) = makeScoring(
            persistence: unrelatedPersistence,
            notificationCenter: notificationCenter)
        let recorder = CommittedWindowRecorder()
        let token = notificationCenter.addObserver(
            forName: HealthKitSyncPublication.name,
            object: observed,
            queue: nil
        ) { notification in
            if let window = HealthKitSyncPublication.window(from: notification) {
                recorder.record(window)
            }
        }
        defer { notificationCenter.removeObserver(token) }
        let first = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        let second = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 300),
            end: Date(timeIntervalSince1970: 400))

        try await unrelated.offer(first)
        XCTAssertTrue(recorder.windows.isEmpty,
                      "preview/test coordinators must not wake the production scoring observer")
        try await observed.offer(second)
        XCTAssertEqual(recorder.windows, [second])

        await unrelated.runAndWait(operation: { _ in true })
        await observed.runAndWait(operation: { _ in true })
    }

    /// CC-1 + CORE-05 (D4): a restored journal no longer closes the fence from init, and a failing receipt
    /// releases it when the run ends. Before the fix, `.initialLoad` was deferred for the whole session.
    @MainActor
    func testRestoredJournalAndFailingReceiptDoNotBlockInitialLoad() async throws {
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        let persistence = PendingWindowMemoryStore()
        persistence.value = window
        let barrier = RepositoryPublicationBarrier.shared
        let scoring = HealthKitScoringCoordinator(
            persistence: persistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier,
            retryPolicy: HealthKitScoringRetryPolicy(maximumAttempts: 3, backoff: [.zero]))

        XCTAssertEqual(scoring.pending, window)
        XCTAssertFalse(barrier.blocksRefreshes, "a restored journal must not fence launch's first refresh")

        await scoring.runAndWait(operation: { _ in false })
        XCTAssertEqual(scoring.pending, window, "the journal survives for a bounded retry")
        XCTAssertFalse(barrier.blocksRefreshes)

        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let loaded = await repository.refresh(.initialLoad)
        XCTAssertTrue(loaded, "initial load runs instead of parking behind a failed scoring journal")
    }

    @MainActor
    func testRepeatedScoringFailureParksAfterThreeAttemptsUntilForeground() async throws {
        let persistence = PendingWindowMemoryStore()
        let notificationCenter = NotificationCenter()
        let (scoring, barrier) = makeScoring(persistence: persistence, notificationCenter: notificationCenter)
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        try await scoring.offer(window)

        var attempts = 0
        for _ in 0..<4 {
            await scoring.runAndWait(operation: { _ in
                attempts += 1
                return false
            })
            XCTAssertFalse(barrier.blocksRefreshes, "every failed run releases the fence")
        }
        XCTAssertEqual(attempts, 3, "the fourth trigger finds the journal parked")
        XCTAssertTrue(scoring.isParked)
        XCTAssertEqual(scoring.pending, window)

        notificationCenter.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        for _ in 0..<100 where scoring.isParked { await Task.yield() }
        XCTAssertFalse(scoring.isParked, "the next foreground retries a parked journal")
        await scoring.runAndWait(operation: { _ in
            attempts += 1
            return true
        })
        XCTAssertEqual(attempts, 4)
        XCTAssertNil(scoring.pending)
        XCTAssertEqual(scoring.consecutiveFailures, 0)
    }

    @MainActor
    func testBackoffDefersTheNextTriggerAndANewImportRetriesAtOnce() async throws {
        let persistence = PendingWindowMemoryStore()
        let (scoring, barrier) = makeScoring(
            persistence: persistence,
            retryPolicy: HealthKitScoringRetryPolicy(maximumAttempts: 3, backoff: [.seconds(600)]))
        let first = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let second = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))
        try await scoring.offer(first)

        var analyzed: [HealthKitSyncWindow] = []
        await scoring.runAndWait(operation: { analyzed.append($0); return false })
        await scoring.runAndWait(operation: { analyzed.append($0); return true })
        XCTAssertEqual(analyzed, [first], "a trigger inside the backoff window does not re-run the analysis")
        XCTAssertFalse(barrier.blocksRefreshes)

        try await scoring.offer(second)
        await scoring.runAndWait(operation: { analyzed.append($0); return true })
        XCTAssertEqual(analyzed, [first, first.union(second)], "new import data retries at once")
        XCTAssertNil(scoring.pending)
    }

    @MainActor
    func testFailedScoringSchedulesOneAutomaticRetryAfterBackoff() async throws {
        let notificationCenter = NotificationCenter()
        let (scoring, _) = makeScoring(
            persistence: PendingWindowMemoryStore(),
            notificationCenter: notificationCenter,
            retryPolicy: HealthKitScoringRetryPolicy(maximumAttempts: 3, backoff: [.milliseconds(20)]))
        let window = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        try await scoring.offer(window)
        let recorder = CommittedWindowRecorder()
        let token = notificationCenter.addObserver(
            forName: HealthKitSyncPublication.name,
            object: scoring,
            queue: nil
        ) { notification in
            if let window = HealthKitSyncPublication.window(from: notification) { recorder.record(window) }
        }
        defer { notificationCenter.removeObserver(token) }

        await scoring.runAndWait(operation: { _ in false })
        for _ in 0..<500 where recorder.windows.isEmpty {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(recorder.windows, [window], "the app's scoring drain observes the retry edge")
    }

    @MainActor
    func testScoringGetsLeaseBetweenContinuousImportBatches() async throws {
        let journal = PendingWindowMemoryStore()
        let (scoring, _) = makeScoring(persistence: PendingWindowMemoryStore())
        let gate = AsyncGate()
        let a = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let b = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))
        var order: [String] = []
        let importer = HealthKitSyncCoordinator(persistence: journal, scoringCoordinator: scoring) { window in
            order.append(window == a ? "importA" : "importB")
            if window == a { await gate.wait() }
            return true
        }
        try importer.offer(a)
        let importing = Task { @MainActor in await importer.runAndWait() }
        while !gate.isWaiting { await Task.yield() }
        try importer.offer(b)
        let publishing = Task { @MainActor in
            await scoring.runAndWait(operation: { _ in order.append("score"); return true })
        }
        while !scoring.isRunning { await Task.yield() }
        gate.open()
        await importing.value
        await publishing.value
        XCTAssertEqual(Array(order.prefix(3)), ["importA", "score", "importB"])
        await scoring.runAndWait(operation: { _ in true })
    }

    @MainActor
    func testFollowUpJournalFailureRetainsFullUnionForRelaunch() async throws {
        let journal = PendingWindowMemoryStore()
        let (scoring, _) = makeScoring(persistence: PendingWindowMemoryStore())
        let gate = AsyncGate()
        let a = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let b = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))
        let importer = HealthKitSyncCoordinator(persistence: journal, scoringCoordinator: scoring) { _ in
            await gate.wait()
            journal.failNextSave = true
            return true
        }
        try importer.offer(a)
        let run = Task { @MainActor in await importer.runAndWait() }
        while !gate.isWaiting { await Task.yield() }
        try importer.offer(b)
        gate.open()
        await run.value
        XCTAssertEqual(journal.value, a.union(b))
        XCTAssertEqual(importer.pending, a.union(b))
        var replay: [HealthKitSyncWindow] = []
        let restored = HealthKitSyncCoordinator(persistence: journal, scoringCoordinator: scoring) {
            replay.append($0)
            return true
        }
        await restored.runAndWait()
        XCTAssertEqual(replay, [a.union(b)])
        XCTAssertNil(journal.value)
        XCTAssertEqual(scoring.pending, a.union(b))
        await scoring.runAndWait(operation: { _ in true })
    }

    @MainActor
    func testFailedAggregationSurvivesRelaunchAndLeavesDurableScoringWork() async throws {
        let importPersistence = PendingWindowMemoryStore()
        let scoringPersistence = PendingWindowMemoryStore()
        let (scoring, barrier) = makeScoring(persistence: scoringPersistence)
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        let failing = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { _ in false }
        try failing.offer(window)
        await failing.runAndWait()

        XCTAssertEqual(importPersistence.value, window)
        XCTAssertEqual(scoring.pending, window,
                       "a failure after local commit/write-back must not strand Recovery scoring")
        XCTAssertEqual(scoringPersistence.value, window)
        XCTAssertFalse(barrier.blocksRefreshes)

        var scored: [HealthKitSyncWindow] = []
        await scoring.runAndWait(operation: { candidate in
            scored.append(candidate)
            return true
        })
        XCTAssertEqual(scored, [window])
        XCTAssertFalse(barrier.blocksRefreshes)

        var recoveredCalls: [HealthKitSyncWindow] = []
        let recovered = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { candidate in
            recoveredCalls.append(candidate)
            return true
        }
        await recovered.runAndWait()

        XCTAssertEqual(recoveredCalls, [window])
        XCTAssertNil(importPersistence.value)
        XCTAssertEqual(scoring.pending, window,
                       "the successful replay creates a fresh scoring edge after the prior one was consumed")
        XCTAssertFalse(barrier.blocksRefreshes)
        await scoring.runAndWait(operation: { _ in true })
    }

    @MainActor
    func testFailedImportSchedulesBackgroundRetryWithoutClearingDurableWork() async throws {
        let importPersistence = PendingWindowMemoryStore()
        let (scoring, _) = makeScoring(persistence: PendingWindowMemoryStore())
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )
        var scheduledRetries = 0
        let coordinator = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring,
            scheduleRetry: { scheduledRetries += 1 }
        ) { _ in false }

        try coordinator.offer(window)
        await coordinator.runAndWait()

        XCTAssertEqual(scheduledRetries, 1)
        XCTAssertEqual(coordinator.pending, window)
        XCTAssertEqual(importPersistence.value, window)
        XCTAssertEqual(scoring.pending, window)
        await scoring.runAndWait(operation: { _ in true })
    }

    @MainActor
    func testScoringHandoffFailureKeepsImportJournalForReplay() async throws {
        let importPersistence = PendingWindowMemoryStore()
        let scoringPersistence = PendingWindowMemoryStore()
        scoringPersistence.failNextSave = true
        let (scoring, barrier) = makeScoring(persistence: scoringPersistence)
        var operationCount = 0
        let coordinator = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { _ in
            operationCount += 1
            return true
        }
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))

        try coordinator.offer(window)
        await coordinator.runAndWait()
        XCTAssertEqual(operationCount, 0,
                       "import must not begin before its scoring dependency is durable")
        XCTAssertEqual(importPersistence.value, window)
        XCTAssertNil(scoring.pending)
        XCTAssertFalse(barrier.blocksRefreshes,
                       "a failed pre-journal with no durable work must reopen publication")

        await coordinator.runAndWait()
        XCTAssertEqual(operationCount, 1, "the idempotent import operation runs after handoff recovery")
        XCTAssertNil(importPersistence.value)
        XCTAssertEqual(scoring.pending, window)
        XCTAssertFalse(barrier.blocksRefreshes)
        await scoring.runAndWait(operation: { _ in true })
    }

    @MainActor
    func testFailedReceiptRetainsJournalButReleasesFenceAfterRun() async throws {
        let persistence = PendingWindowMemoryStore()
        let (scoring, barrier) = makeScoring(persistence: persistence)
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        try await scoring.offer(window)

        var attempts = 0
        await scoring.runAndWait(operation: { _ in
            attempts += 1
            return false
        })
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(scoring.pending, window)
        XCTAssertEqual(persistence.value, window)
        XCTAssertFalse(barrier.blocksRefreshes, "a failed receipt must not keep every typed refresh deferred")

        await scoring.runAndWait(operation: { _ in
            attempts += 1
            return true
        })
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(scoring.pending)
        XCTAssertNil(persistence.value)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    @MainActor
    func testFailedRepositoryPublicationRetainsJournalForReplayWithoutTheFence() async throws {
        let persistence = PendingWindowMemoryStore()
        let (scoring, barrier) = makeScoring(persistence: persistence)
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        try await scoring.offer(window)

        var publications = 0
        await scoring.runAndWait(
            analyze: { _ in true },
            publish: { _ in
                publications += 1
                return false
            })

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(scoring.pending, window)
        XCTAssertEqual(persistence.value, window)
        XCTAssertFalse(barrier.blocksRefreshes)

        await scoring.runAndWait(
            analyze: { _ in true },
            publish: { _ in
                publications += 1
                return true
            })
        XCTAssertEqual(publications, 2)
        XCTAssertNil(scoring.pending)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    @MainActor
    func testPendingPersistenceFailureDoesNotStartOrLoseInMemoryWork() async {
        let importPersistence = PendingWindowMemoryStore()
        let (scoring, barrier) = makeScoring(persistence: PendingWindowMemoryStore())
        importPersistence.failNextSave = true
        var operationCount = 0
        let coordinator = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { _ in
            operationCount += 1
            return true
        }

        XCTAssertThrowsError(try coordinator.offer(HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )))
        await coordinator.runAndWait()

        XCTAssertEqual(operationCount, 0)
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(importPersistence.value)
        XCTAssertNil(scoring.pending)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    func testAnalysisRangeCoversRecentCommittedDays() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 7, day: 25, hour: 8),
            end: try date(calendar, year: 2026, month: 7, day: 27, hour: 10))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 3)
    }

    func testAnalysisRangeRecomputesForwardDependencyClosureFromHistoricalChange() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 7, day: 10),
            end: try date(calendar, year: 2026, month: 7, day: 12))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 18,
                       "historical HRV/RHR can affect every later baseline-dependent day")
    }

    func testAnalysisRangeUsesCalendarDaysAcrossSpringDST() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 3, day: 9)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 3, day: 7, hour: 23),
            end: try date(calendar, year: 2026, month: 3, day: 9, hour: 1))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 3,
                       "the 23-hour DST day still counts as one civil day")
    }

    func testFutureOnlyWindowFailsClosedToToday() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 7, day: 28),
            end: try date(calendar, year: 2026, month: 7, day: 29))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 1)
    }

    @MainActor
    func testInitialLargeHistoryIsPagedInBoundedBatches() async throws {
        let total = 20_000
        let loader = GeneratedHeartRatePageLoader(totalSamples: total)
        let pager = HealthKitAnchorPager(loader: loader, pageLimit: 500)
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRate))

        let result = try await pager.scan(type: type, predicate: nil, anchor: nil)

        XCTAssertEqual(result.sampleCount, total)
        XCTAssertEqual(result.pageCount, 41, "An exact multiple requires one final empty page")
        XCTAssertTrue(result.wasInitialScan)
        XCTAssertEqual(loader.maximumReturnedCount, 500)
        XCTAssertTrue(loader.requestedLimits.allSatisfy { $0 == 500 })
        XCTAssertEqual(result.oldestSampleDate, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.newestSampleDate, Date(timeIntervalSince1970: TimeInterval(total - 1)))
    }

    @MainActor
    func testPagingFailureDoesNotProduceACommittableFinalAnchor() async throws {
        let loader = GeneratedHeartRatePageLoader(totalSamples: 1_000, failOnPage: 2)
        let pager = HealthKitAnchorPager(loader: loader, pageLimit: 500)
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRate))

        do {
            _ = try await pager.scan(type: type, predicate: nil, anchor: nil)
            XCTFail("Expected the injected page fault")
        } catch GeneratedHeartRatePageLoader.Failure.injected {
            XCTAssertEqual(loader.requestedLimits.count, 2)
        }
    }
}
#endif
