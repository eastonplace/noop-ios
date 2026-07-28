import HealthKit
import XCTest
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
    @MainActor
    private func makeScoring(
        persistence: PendingWindowMemoryStore,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (HealthKitScoringCoordinator, RepositoryPublicationBarrier) {
        let barrier = RepositoryPublicationBarrier()
        return (
            HealthKitScoringCoordinator(
                persistence: persistence,
                notificationCenter: notificationCenter,
                publicationBarrier: barrier),
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

        XCTAssertEqual(calls, [a, a.union(b)])
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(importPersistence.value)
        XCTAssertEqual(scoring.pending, a.union(b))
        XCTAssertEqual(scoringPersistence.value, a.union(b))
        XCTAssertEqual(recorder.windows, [a, a.union(b)],
                       "each pre-import journal edge is durable; scoring consumes only the final union")
        XCTAssertTrue(barrier.blocksRefreshes)

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

    @MainActor
    func testRestoredScoringJournalClosesPublicationBeforeDrain() async throws {
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        let persistence = PendingWindowMemoryStore()
        persistence.value = window
        let (scoring, barrier) = makeScoring(persistence: persistence)

        XCTAssertEqual(scoring.pending, window)
        XCTAssertTrue(barrier.blocksRefreshes,
                      "launch must fence Repository before AppModel schedules its initial refresh")

        await scoring.runAndWait(operation: { candidate in
            XCTAssertEqual(candidate, window)
            return true
        })
        XCTAssertNil(scoring.pending)
        XCTAssertNil(persistence.value)
        XCTAssertFalse(barrier.blocksRefreshes)
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
        XCTAssertTrue(barrier.blocksRefreshes)

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
        XCTAssertTrue(barrier.blocksRefreshes)
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
        XCTAssertTrue(barrier.blocksRefreshes)
        await scoring.runAndWait(operation: { _ in true })
    }

    @MainActor
    func testFailedScoringRetainsJournalAndPublicationFenceUntilLaterDrain() async throws {
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
        XCTAssertTrue(barrier.blocksRefreshes)

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
    func testFailedRepositoryPublicationRetainsJournalAndFenceForReplay() async throws {
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
        XCTAssertTrue(barrier.blocksRefreshes)

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
        XCTAssertEqual(range.publicationDays, 120)
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
        XCTAssertEqual(range.publicationDays, 120)
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
