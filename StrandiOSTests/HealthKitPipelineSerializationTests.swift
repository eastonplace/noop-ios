import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
private final class PipelineWindowMemoryStore: HealthKitPendingWindowPersisting {
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
private final class PipelineGate {
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

@MainActor
final class HealthKitPipelineSerializationTests: XCTestCase {
    private func waitUntil(
        attempts: Int = 500,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for HealthKit pipeline state")
    }

    func testRevisionAdvanceDuringAnalysisSkipsTheOlderPublication() async throws {
        let persistence = PipelineWindowMemoryStore()
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: persistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier)
        let gate = PipelineGate()
        let first = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        let second = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 50),
            end: Date(timeIntervalSince1970: 300))
        try await scoring.offer(first)
        XCTAssertTrue(barrier.blocksRefreshes)

        var analyzed: [HealthKitSyncWindow] = []
        var published: [HealthKitSyncWindow] = []
        let task = Task { @MainActor in
            await scoring.runAndWait(
                analyze: { window in
                    analyzed.append(window)
                    if analyzed.count == 1 { await gate.wait() }
                    return true
                },
                publish: { published.append($0); return true })
        }
        try await waitUntil { gate.isWaiting }

        // This is a defensive direct offer that bypasses the production import lease. The coordinator must
        // still detect the revision edge after analysis and skip publication of the superseded first window.
        try await scoring.offer(second)
        gate.open()
        await task.value

        XCTAssertEqual(analyzed, [first, first.union(second)])
        XCTAssertEqual(published, [first.union(second)])
        XCTAssertNil(scoring.pending)
        XCTAssertNil(persistence.value)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    func testImportLeaseExcludesWritesUntilPublicationFinishes() async throws {
        let persistence = PipelineWindowMemoryStore()
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: persistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier)
        let publishGate = PipelineGate()
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        try await scoring.offer(window)

        var events: [String] = []
        let scoringTask = Task { @MainActor in
            await scoring.runAndWait(
                analyze: { _ in
                    events.append("analyze")
                    return true
                },
                publish: { _ in
                    events.append("publish-start")
                    await publishGate.wait()
                    events.append("publish-end")
                    return true
                })
        }
        try await waitUntil { publishGate.isWaiting }

        let importTask = Task { @MainActor in
            await scoring.withImportLease {
                events.append("import")
            }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events, ["analyze", "publish-start"],
                       "HealthKit rows must not change during Repository/widget publication")
        XCTAssertTrue(barrier.blocksRefreshes,
                      "unrelated Repository refreshes stay fenced through publication")

        publishGate.open()
        await scoringTask.value
        await importTask.value
        XCTAssertEqual(events, ["analyze", "publish-start", "publish-end", "import"])
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    func testFailedImportStillLeavesDurableScoringWorkAndFence() async throws {
        let importPersistence = PipelineWindowMemoryStore()
        let scoringPersistence = PipelineWindowMemoryStore()
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: scoringPersistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier)
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        var importAttempts = 0
        let importer = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { _ in
            importAttempts += 1
            // Models a failure after local HealthKit rows may already have committed, such as outbound
            // NOOP→Health write-back failure. Import retry remains pending, but derived scoring cannot be lost.
            return false
        }

        try importer.offer(window)
        await importer.runAndWait()

        XCTAssertEqual(importAttempts, 1)
        XCTAssertEqual(importer.pending, window)
        XCTAssertEqual(importPersistence.value, window)
        XCTAssertEqual(scoring.pending, window)
        XCTAssertEqual(scoringPersistence.value, window)
        XCTAssertTrue(barrier.blocksRefreshes,
                      "fresh vitals cannot publish while their Recovery scoring journal remains")

        var scored: [HealthKitSyncWindow] = []
        await scoring.runAndWait(operation: { candidate in
            scored.append(candidate)
            return true
        })
        XCTAssertEqual(scored, [window])
        XCTAssertNil(scoring.pending)
        XCTAssertFalse(barrier.blocksRefreshes)
        XCTAssertEqual(importer.pending, window,
                       "scoring success must not falsely acknowledge the failed import retry")
    }

    func testWidenedImportCompletesBeforeAnyScoringPublication() async throws {
        let importPersistence = PipelineWindowMemoryStore()
        let scoringPersistence = PipelineWindowMemoryStore()
        let barrier = RepositoryPublicationBarrier()
        let scoring = HealthKitScoringCoordinator(
            persistence: scoringPersistence,
            notificationCenter: NotificationCenter(),
            publicationBarrier: barrier)
        let gate = PipelineGate()
        let first = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 300))
        let second = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 250))
        var imported: [HealthKitSyncWindow] = []
        let importer = HealthKitSyncCoordinator(
            persistence: importPersistence,
            scoringCoordinator: scoring
        ) { window in
            imported.append(window)
            if imported.count == 1 { await gate.wait() }
            return true
        }

        try importer.offer(first)
        let importTask = Task { @MainActor in await importer.runAndWait() }
        try await waitUntil { gate.isWaiting }

        var analyzed: [HealthKitSyncWindow] = []
        var published: [HealthKitSyncWindow] = []
        let scoringTask = Task { @MainActor in
            await scoring.runAndWait(
                analyze: { analyzed.append($0); return true },
                publish: { published.append($0); return true })
        }
        try importer.offer(second)
        gate.open()
        await importTask.value
        await scoringTask.value

        let union = first.union(second)
        XCTAssertEqual(imported, [first, union])
        XCTAssertEqual(analyzed, [union],
                       "the import lease keeps the first journal from scoring before the widened replay")
        XCTAssertEqual(published, [union])
        XCTAssertNil(importer.pending)
        XCTAssertNil(scoring.pending)
        XCTAssertFalse(barrier.blocksRefreshes)
    }
}
#endif
