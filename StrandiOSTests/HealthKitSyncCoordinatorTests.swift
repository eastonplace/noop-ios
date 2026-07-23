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
    func testObserverBWidensPendingWindowWhileObserverAIsSyncing() async throws {
        let persistence = PendingWindowMemoryStore()
        let gate = AsyncGate()
        var calls: [HealthKitSyncWindow] = []
        let coordinator = HealthKitSyncCoordinator(persistence: persistence) { window in
            calls.append(window)
            if calls.count == 1 { await gate.wait() }
            return true
        }
        let a = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 300)
        )
        let b = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 250)
        )

        try coordinator.offer(a)
        let firstRun = Task { @MainActor in await coordinator.runAndWait() }
        while !gate.isWaiting { await Task.yield() }

        try coordinator.offer(b)
        XCTAssertEqual(persistence.value, a.union(b), "B must be durable before A resumes")
        gate.open()
        await firstRun.value

        XCTAssertEqual(calls, [a, a.union(b)])
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(persistence.value)
    }

    @MainActor
    func testFailedAggregationSurvivesRelaunchAndRetries() async throws {
        let persistence = PendingWindowMemoryStore()
        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )
        let failing = HealthKitSyncCoordinator(persistence: persistence) { _ in false }
        try failing.offer(window)
        await failing.runAndWait()
        XCTAssertEqual(persistence.value, window)

        var recoveredCalls: [HealthKitSyncWindow] = []
        let recovered = HealthKitSyncCoordinator(persistence: persistence) { candidate in
            recoveredCalls.append(candidate)
            return true
        }
        await recovered.runAndWait()

        XCTAssertEqual(recoveredCalls, [window])
        XCTAssertNil(persistence.value)
    }

    @MainActor
    func testPendingPersistenceFailureDoesNotStartOrLoseInMemoryWork() async {
        let persistence = PendingWindowMemoryStore()
        persistence.failNextSave = true
        var operationCount = 0
        let coordinator = HealthKitSyncCoordinator(persistence: persistence) { _ in
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
        XCTAssertNil(persistence.value)
    }

    @MainActor
    func testInitialLargeHistoryIsPagedInBoundedBatches() async throws {
        let total = 20_000
        let loader = GeneratedHeartRatePageLoader(totalSamples: total)
        let pager = HealthKitAnchorPager(loader: loader, pageLimit: 500)
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRate))

        let result = try await pager.scan(type: type, predicate: nil, priorAnchor: nil)

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
            _ = try await pager.scan(type: type, predicate: nil, priorAnchor: nil)
            XCTFail("Expected the injected page fault")
        } catch GeneratedHeartRatePageLoader.Failure.injected {
            XCTAssertEqual(loader.requestedLimits.count, 2)
        }
    }
}
#endif
